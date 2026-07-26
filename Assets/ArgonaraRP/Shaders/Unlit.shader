Shader "Argonara RP/Unlit"
{
    Properties
    {
        _BaseMap("基础贴图",2D)="white"{}
        _BaseColor("基础颜色",Color) = (1.0, 1.0, 1.0, 1.0)
        
        _Cutoff ("Alpha Cutoff", Range(0.0, 1.0)) = 0.5
        [Toggle(_CLIPPING)]_Clipping("Alpha Clipping",Float) = 0
    	
        [HDR] _EmissionColor("Emission", Color) = (0.0, 0.0, 0.0, 0.0)
        
        [Toggle(_VERTEX_COLORS)] _VertexColors ("Vertex Colors", Float) = 0
        
        [Enum(UnityEngine.Rendering.BlendMode)]_SrcBlend("Src Blend",Float) = 1
        [Enum(UnityEngine.Rendering.BlendMode)]_DstBlend("Dst Blend",Float) = 0
        
        [Enum(Off,0,On,1)]_ZWrite("Z Write",Float) = 1
        
        [KeywordEnum(On, Clip, Dither, Off)]_Shadows("Cast Shadows Mode",Float)=0
    }
    SubShader
    {
		HLSLINCLUDE
		#include "../ShaderLibrary/Common.hlsl"
		#include "UnlitInput.hlsl"
		ENDHLSL
        Pass
        {
            Tags{"LightMode" = "SRPDefaultUnlit"}//不写Tag的LightMode的时候，就默认是SRPDefaultUnlit
            Blend [_SrcBlend] [_DstBlend], One OneMinusSrcAlpha
            ZWrite [_ZWrite]
            
            HLSLPROGRAM
            #pragma shader_feature _CLIPPING
            #pragma shader_feature _VERTEX_COLORS
            #pragma multi_compile_instancing//它一定要写在vert和frag前面吗？为啥？
            #pragma vertex UnlitPassVertex
            #pragma fragment UnlitPassFragment
            #include "UnlitPass.hlsl"
            ENDHLSL
        }

        Pass
        {
            Tags{"LightMode" = "ShadowCaster"}
            
            ColorMask 0

			HLSLPROGRAM
			#pragma target 3.5
			//#pragma shader_feature _CLIPPING
			#pragma shader_feature _ _SHADOWS_CLIP _SHADOWS_DITHER//说是用空的关键字表示打开和关闭
			#pragma multi_compile_instancing
			#pragma vertex ShadowCasterPassVertex
			#pragma fragment ShadowCasterPassFragment
			#include "ShadowCasterPass.hlsl"
			ENDHLSL
        }

		Pass
		{
			Tags{"LightMode" = "Meta"}
			Cull Off
			
			HLSLPROGRAM
			#pragma target 3.5
			#pragma vertex MetaPassVertex
			#pragma fragment MetaPassFragment
			#include "MetaPass.hlsl"
			ENDHLSL
		}

		Pass
        {
            Tags{"LightMode" = "ArgonaraGBuffer"}
            Blend Off
            ZWrite On
            
            HLSLPROGRAM
            #pragma shader_feature _CLIPPING
            #pragma shader_feature _VERTEX_COLORS
            #pragma multi_compile_instancing//它一定要写在vert和frag前面吗？为啥？
            #pragma vertex UnlitPassVertex
            #pragma fragment UnlitPassFragmentGBuffer
            #include "UnlitPass.hlsl"
            ENDHLSL
        }
    }
    CustomEditor "ArgonaraShaderGUI"
}
