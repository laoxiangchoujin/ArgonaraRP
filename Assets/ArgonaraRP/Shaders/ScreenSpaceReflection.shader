//屏幕空间反射（SSR）：把"每个像素朝反射方向找交点"算成一张独立的全屏反射图，
//再模糊，最后交给接收面（水面等材质）自己采样合成。
//
//绘制顺序（都在不透明 + 天空盒之后、透明之前）：
//  ① 追踪（trace）→ _SSRTex
//  ② 横向模糊：_SSRTex → _SSRTex_TempBlur
//  ③ 纵向模糊：_SSRTex_TempBlur → _SSRTex
//  ④ 接收面（水/玻璃等）采样 _SSRTex，用自身法线 + 粗糙度 + Fresnel 合成
//
//Pass 顺序：C# 是按 pass 索引调用的（见 CameraRendererDeferred 里的 SSRPass 枚举），
//所以两边的顺序**必须完全一致**，改一边就得同步改另一边：
//  0 = Trace（追踪）    1 = BlurHorizontal    2 = BlurVertical    3 = Composite（间接高光合成，还没实现）
//
//两张图的尺寸和格式由 C# 决定：_SSRTex / _SSRTex_TempBlur 都是半分辨率、HDR。
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

        //3.间接高光合成（延迟专用）：把"GBuffer里没写的间接高光"加回颜色附件。
        //  这趟的渲染目标**就是颜色附件本身**（场景颜色已经在里面），所以"加到画面上"这步不用自己采样屏幕纹理
        //  —— 采样自己的渲染目标是同一张RT边读边写，属于未定义行为；这里交给混合状态做：dst = 1×src + 1×dst
        //  shader里输出alpha=0，免得把颜色附件的alpha也加上去
        Pass
        {
            Name "SSR Composite"
            Blend One One

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment CompositePassFragment
            ENDHLSL
        }
    }
}
