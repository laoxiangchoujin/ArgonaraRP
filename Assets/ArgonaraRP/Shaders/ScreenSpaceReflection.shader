//屏幕空间反射（SSR）：把"每个像素朝反射方向找交点"算成一张独立的全屏反射图，再横竖模糊两趟。
//产出的 _SSRTex（rgb=反射色、a=可信度）**本帧不消费，下一帧才用**（两条路都一样）：
//  ① 不透明物体：在**自己的物体pass**里（前向 Lit / 延迟 GBuffer 与地形）采"上一帧"这张图，
//     按可信度 a 与环境反射做 lerp（GI.hlsl 的三参 SampleEnvironment）；
//  ② 接收面（水/玻璃等透明物）：也采这张图，用自身法线 + 粗糙度 + Fresnel 合成。
//⇒ 所以这里**没有"合成pass"**：混合发生在每个物体自己的着色里（采样时 a=0 就自动退回环境反射）。
//
//绘制顺序（都在不透明 + 天空盒之后、透明之前）：
//  ① 追踪（trace）→ 本帧那张反射图
//  ② 横向模糊：→ _SSRTex_TempBlur
//  ③ 纵向模糊：→ 回到本帧那张（帧末交换双缓冲索引，下一帧消费它）
//
//Pass 顺序：C# 是按 pass 索引调用的（见 ScreenSpaceReflection.cs 里的 Pass 枚举），
//所以两边的顺序**必须完全一致**，改一边就得同步改另一边：
//  0 = Trace（追踪）    1 = BlurHorizontal    2 = BlurVertical
//
//两张图由 C# 决定（**跨帧持久的双缓冲**，两帧轮换）：_SSRTex / _SSRTex_TempBlur 都是半分辨率、HDR。
//所有 fragment 函数体都写在 ScreenSpaceReflection.hlsl 里，这里只留 pass 名和 #pragma。
Shader "Hidden/ArgonaraRP/Screen Space Reflection"
{
    SubShader
    {
        //全屏绘制：不剔除、不做深度测试、不写深度（和 ScreenSpacePCSS 一致）
        Cull Off
        ZTest Always
        ZWrite Off

        HLSLINCLUDE
        #include "../ShaderLibrary/Common.hlsl"
        //DefaultPassVertex（全屏三角）以及 _GBuffer1~4 / _CameraDepthTexture / _CameraColorTexture 等声明都在这里
        #include "CameraRendererPasses.hlsl"
        //SSR 自己的纹素尺寸、两张图、以及各 pass 的函数体都在这里（追踪代码之后也放这里）
        #include "ScreenSpaceReflection.hlsl"
        ENDHLSL

        //0.追踪（trace）：屏幕空间步进找交点 → _SSRTex
        //  算法说明写在 ScreenSpaceReflection.hlsl 里（traceRay / alphaCalc 等函数）
        Pass
        {
            Name "SSR Trace"

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment TracePassFragment
            ENDHLSL
        }

        //1.横向模糊：_SSRTex → _SSRTex_TempBlur
        //  算法和"为什么不用双边滤波"的说明写在 ScreenSpaceReflection.hlsl 里
        Pass
        {
            Name "SSR Blur Horizontal"

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment BlurHorizontalPassFragment
            ENDHLSL
        }

        //2.纵向模糊：_SSRTex_TempBlur → _SSRTex
        Pass
        {
            Name "SSR Blur Vertical"

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment BlurVerticalPassFragment
            ENDHLSL
        }

    }
}
