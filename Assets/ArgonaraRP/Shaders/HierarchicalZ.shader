//分层深度图（Hi-Z）的生成：把深度图做成一条 mip 链 —— 每级的一个纹素 = 上一级 2×2 块里**离相机最近**的那个深度。
//Unity 默认是 ReverseZ（值越大 = 越近）⇒ 取 max（若哪天换成普通 Z 方向，这里要改成 min）。
//用途：屏幕空间追踪（SSR 等）按 mip 级决定步长 —— 安全就升级（步长翻倍）、碰到就退一级再走，
//      比线性步进快得多；而且"没碰到"这个结论永远可靠（2×2 取最近 = 保守，不会漏掉真交点）。
//
//Pass 顺序：C# 是按 pass 索引调用的（见 HierarchicalZ.cs 里的 Pass 枚举），
//所以两边的顺序**必须完全一致**，改一边就得同步改另一边：
//  0 = Mip0（深度图 → 主图 mip0）      1 = Downsample（主图上一级 → 主图当前级）
//
//⚠️ 降采样那趟是"同一张图既读又写"（读主图上一级、写主图当前级）。D3D 对这种用法不保证（会告警），
//   真出问题就退回"每级一张临时图 + CopyTexture"—— **只需改 C#**，这趟 shader 不用动（把临时图当 _HiZTex 绑进来即可）。
Shader "Hidden/ArgonaraRP/Hierarchical Z"
{
    SubShader
    {
        //全屏绘制：不剔除、不做深度测试、不写深度（和 SSR / PCSS 一致）
        Cull Off
        ZTest Always
        ZWrite Off

        HLSLINCLUDE
        #include "../ShaderLibrary/Common.hlsl"
        //DefaultPassVertex（全屏三角）以及 _CameraDepthTexture 等声明都在这个文件里
        #include "CameraRendererPasses.hlsl"

        //=========================================================
        //====== Hi-Z 的图 ======
        //=========================================================
        //带 mip 链的主图（屏幕尺寸、单通道浮点）：mip0 就是深度图本身，mip i = mip i-1 的 2×2 取最近。
        //由 C# 每帧 SetGlobalTexture 绑定；追踪那趟也按 mip 采它。
        TEXTURE2D(_HiZTex);
        //（另有一个 _MaxHiZMipLevel = 级数-1，是给追踪那趟 clamp mip 用的，声明在 ScreenSpaceReflection.hlsl 里）

        //【降采样那趟的"源"】= 主图的第 _HiZSourceMipLevel 级（由 C# 每级画之前告诉它，就是"上一级"）
        int _HiZSourceMipLevel;
        //源级的纹素尺寸：xy = 1/宽、1/高（取邻居的偏移要用它），zw = 宽、高（和项目的 _SSRTexelSize 一个口径）
        float4 _HiZSourceTexelSize;

        //=========================================================
        //====== 0.mip0：深度图 → 主图的 mip0 ======
        //=========================================================
        //1:1，其实只是转格式：**不能用 CopyTexture**（深度附件是深度格式，主图是单通道浮点，跨格式拷不了）
        float4 HiZMip0PassFragment (Varyings input) : SV_Target
        {
            //主图 mip0 和屏幕同尺寸 ⇒ 直接按同一个 uv 采深度图即可，不做任何过滤
            return SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, input.screenUV);
        }

        //=========================================================
        //====== 1.降采样：主图上一级 → 主图当前级 ======
        //=========================================================
        //目标像素取源级 2×2 块（= 目标像素中心的左上/右上/左下/右下 4 个纹素）里的**最大**深度：
        //  ① 必须 **point** 采样：线性采样会把 4 个纹素平均 ⇒ max 被抹平 ⇒ 不保守，追踪会漏交
        //  ② 偏移用 **±0.5 个源纹素**（_HiZSourceTexelSize.xy × 0.5）：目标像素中心正好落在那 4 个纹素的交界中心
        float4 HiZDownsamplePassFragment (Varyings input) : SV_Target
        {
            float2 uv = input.screenUV;
            float2 halfTexel = _HiZSourceTexelSize.xy * 0.5;//±0.5 个**源级**纹素：目标像素中心正好在源 2×2 块的中心

            //源级 2×2 块 = 相对该块中心的左上/右上/左下/右下四个纹素（point 采样，精确命中各自中心）
            float4 depths = float4(
                SAMPLE_TEXTURE2D_LOD(_HiZTex, sampler_point_clamp, uv + float2(-halfTexel.x, -halfTexel.y), _HiZSourceMipLevel).r,
                SAMPLE_TEXTURE2D_LOD(_HiZTex, sampler_point_clamp, uv + float2( halfTexel.x, -halfTexel.y), _HiZSourceMipLevel).r,
                SAMPLE_TEXTURE2D_LOD(_HiZTex, sampler_point_clamp, uv + float2(-halfTexel.x,  halfTexel.y), _HiZSourceMipLevel).r,
                SAMPLE_TEXTURE2D_LOD(_HiZTex, sampler_point_clamp, uv + float2( halfTexel.x,  halfTexel.y), _HiZSourceMipLevel).r
            );

            //ReverseZ：值越大 = 越近 ⇒ 取 max = 这一块里离相机最近的表面（保守：追踪据此判定"这块没东西"永远安全）
            return max(max(depths.x, depths.y), max(depths.z, depths.w));
        }
        ENDHLSL

        //0.mip0：深度图 → 主图的 mip0
        Pass
        {
            Name "HiZ Mip0"

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment HiZMip0PassFragment
            ENDHLSL
        }

        //1.降采样：主图上一级 → 主图当前级
        Pass
        {
            Name "HiZ Downsample"

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment HiZDownsamplePassFragment
            ENDHLSL
        }
    }
}
