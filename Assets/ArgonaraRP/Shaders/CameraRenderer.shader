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
    }
}
