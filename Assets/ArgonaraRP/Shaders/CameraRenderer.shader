Shader "Hidden/ArgonaraRP/Camera Renderer"//hidden的不会在inspector里显示
{
    SubShader
    {
        Cull Off//后处理，，，不剔除，忽略深度，，，话说为啥不剔除
		ZTest Always
		ZWrite Off

		HLSLINCLUDE
		#include "../ShaderLibrary/Common.hlsl"
		#include "CameraRendererPasses.hlsl"
		ENDHLSL
		
		
		//目前只有这一个有需要，当启用把颜色渲染到中间纹理，而不是帧缓冲区的时候，
		//若用CopyTexture函数只能再复制到另一个RT，而不能到屏幕的帧缓冲区。所以这里用shader再画一遍
        Pass
        {
            Name "Copy"

            Blend [_CameraSrcBlend] [_CameraDstBlend]
            
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DefaultPassVertex
            #pragma fragment CopyPassFragment
			ENDHLSL
        }

		Pass
        {
            Name "Copy Depth"
            
            ColorMask 0
            ZWrite On
            //不写入颜色，启用深度写入，是Copy Depth的需求
            
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DefaultPassVertex
            #pragma fragment CopyDepthPassFragment
			ENDHLSL
        }

		//针对Opaque Lit物体，数据已写入GBuffer，读取GT，计算光照
		Pass
		{
			Name "Deferred Lighting"

			HLSLPROGRAM
			#pragma target 3.5
			
			
            #pragma multi_compile _ _DIRECTIONAL_PCF3 _DIRECTIONAL_PCF5 _DIRECTIONAL_PCF7//只有一个_的是没有这些关键字，也就是pcf2x2
            #pragma multi_compile _ _CASCADE_BLEND_SOFT _CASCADE_BLEND_DITHER
			
			//1.！和forward不一样的地方！shader_feature的variant选择靠材质关键字，DrawProcedural用的material上没开_RECEIVE_SHADOWS keyword，所以会是无阴影。
			//换成，multi_compile 的 variant 选择靠全局关键字，Unity SRP 自动管理它，所以能正确接受阴影。
			//一般deferred不支持opaque lit物体逐物体选择是否接受阴影，这里我也只让它全局控制了。（或者其实可以当作1位数据写入GBuffer但觉得没必要）
            #pragma multi_compile  _RECEIVE_SHADOWS
            #pragma multi_compile _ _SHADOW_MASK_ALWAYS _SHADOW_MASK_DISTANCE	//3.疑似还没支持？
			
			//2.！和forward不一样的地方！延迟 Pass 是 Fullscreen Quad，没有"逐物体"的概念。_LIGHTS_PER_OBJECT是让点光源循环走 unity_LightIndices（逐物体索引）
			//这对全屏 Pass 没意义，索引全是 0，所以注释掉，走全局循环GetOtherLightCount()
            //#pragma multi_compile _ _LIGHTS_PER_OBJECT//针对点光源或聚光灯的逐物体光照
            #pragma multi_compile _ _OTHER_PCF3 _OTHER_PCF5 _OTHER_PCF7
            #pragma multi_compile_instancing
			
			#pragma vertex DefaultPassVertex
			#pragma fragment DeferredLightPassFragment
			ENDHLSL
		}
    }
}
