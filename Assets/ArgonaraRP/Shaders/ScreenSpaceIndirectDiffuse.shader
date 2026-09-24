//屏幕空间间接光（SSGI）：半分辨率的四趟 —— 追踪 → 时间累积 → 横竖两趟双边，产出一张 GI 图。
//函数体都写在 ScreenSpaceIndirectDiffuse.hlsl 里，这里只留 Pass 名和 #pragma。
//（输出口径：rgb = 间接漫反射的辐照度、a = 可信度；物体着色在 GI.hlsl 的 GetGI 里按 a 与烘焙结果混）
//
//Pass 顺序：C# 是按 pass 索引调用的（见 ScreenSpaceIndirectDiffuse.cs 里的 Pass 枚举），两边**必须完全一致**：
//  0 = Trace（追踪）  1 = Temporal（时间累积）  2 = BlurHorizontal（横向双边）  3 = BlurVertical（纵向双边）
Shader "Hidden/ArgonaraRP/Screen Space Indirect Diffuse"
{
    SubShader
    {
        //全屏绘制：不剔除、不做深度测试、不写深度
        Cull Off
        ZTest Always
        ZWrite Off

        HLSLINCLUDE
        #include "../ShaderLibrary/Common.hlsl"
        //DefaultPassVertex（全屏三角）+ _GBuffer1~4 / _CameraDepthTexture / _SSGITex 等声明都在这里
        #include "CameraRendererPasses.hlsl"
        //SSGI 自己的纹素尺寸、几张图、参数，以及四个 pass 的函数体都在这里
        #include "ScreenSpaceIndirectDiffuse.hlsl"
        ENDHLSL

        //0.追踪：深度 → 半球方向 → Hi-Z 步进 → (GI, 可信度) → _SSGITraceTex
        Pass
        {
            Name "SSGI Trace"

            HLSLPROGRAM
            #pragma target 3.5

            //命中点的阴影：**主光那一路不依赖任何关键字**（`SsgiShadeHit` 里自接调 `GetCascadedShadow`，
            //照 ScreenSpacePCSS.shader 的做法绕开 `_RECEIVE_SHADOWS` 门控）。
            //这句 pragma 只影响**其他光**（`GetOtherLight` 内部的 `GetOtherShadowAttenuation` 是门控的）：
            //`_RECEIVE_SHADOWS` 是全局关键字、由对象材质的开关带起来 ⇒ 状态不完全可控，所以主光不靠它。
            #pragma multi_compile _ _RECEIVE_SHADOWS

            #pragma vertex DefaultPassVertex
            #pragma fragment TracePassFragment
            ENDHLSL
        }

        //1.时间累积：_SSGISourceTex（本帧追踪）+ _SSGITex（历史）→ _SSGITempTex
        Pass
        {
            Name "SSGI Temporal"

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment TemporalPassFragment
            ENDHLSL
        }

        //2.横向双边：_SSGISourceTex → 目标
        Pass
        {
            Name "SSGI Blur Horizontal"

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment BlurHorizontalPassFragment
            ENDHLSL
        }

        //3.纵向双边：_SSGISourceTex → 目标（本帧最后落到"持久图里该写的那张"）
        Pass
        {
            Name "SSGI Blur Vertical"

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment BlurVerticalPassFragment
            ENDHLSL
        }
    }
}
