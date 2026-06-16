Shader "Argonara RP/Lit"
{
    Properties
    {
        _BaseMap("基础贴图", 2D) = "white" {}
		_BaseColor("基础颜色", Color) = (0.5, 0.5, 0.5, 1.0)
        
        _Cutoff ("Alpha Cutoff", Range(0.0, 1.0)) = 0.5
        [Toggle(_CLIPPING)]_Clipping("Alpha Clipping",Float) = 0
        
        _Metallic ("Metallic", Range(0, 1)) = 0
		_Smoothness ("Smoothness", Range(0, 1)) = 0.5
        
        [Toggle(_PREMULTIPLY_ALPHA)]_PremulAlpha("Premultiply Alpha（如果是玻璃，启用它，并且One,OneMinusSrcAlpha）",Float)=0
        
        [Enum(UnityEngine.Rendering.BlendMode)]_SrcBlend("Src Blend",Float) = 5
        [Enum(UnityEngine.Rendering.BlendMode)]_DstBlend("Dst Blend",Float) = 8
        
        [Enum(Off,0,On,1)]_ZWrite("Z Write",Float) = 1
    	
    	[KeywordEnum(On, Clip, Dither, Off)]_Shadows("Cast Shadows Mode",Float)=0
    	
    	[Toggle(_RECEIVE_SHADOWS)] _ReceiveShadows ("Receive Shadows", Float) = 1
    }
    SubShader
    {

        Pass
        {
            Tags {"LightMode" = "ArgonaraLit"}
            Blend [_SrcBlend] [_DstBlend]
            ZWrite [_ZWrite]
            
            HLSLPROGRAM
            #pragma target 3.5//避免在OpenGL ES 2.0和WebGL 1.0编译这些shader（因为不支持循环）
            
            #pragma shader_feature _CLIPPING
            #pragma shader_feature _PREMULTIPLY_ALPHA
            #pragma multi_compile _ _DIRECTIONAL_PCF3 _DIRECTIONAL_PCF5 _DIRECTIONAL_PCF7//只有一个_的是没有这些关键字，也就是pcf2x2
            #pragma multi_compile _ _CASCADE_BLEND_SOFT _CASCADE_BLEND_DITHER
            #pragma shader_feature _RECEIVE_SHADOWS
            #pragma multi_compile_instancing
            #pragma vertex LitPassVertex
            #pragma fragment LitPassFragment
            #include "LitPass.hlsl"
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
    }
    CustomEditor "ArgonaraShaderGUI"//双引号里填这个ShaderGUI的类名就可，unity会自动搜索叫这个名字且继承了ShaderGUI类的class来重绘inspector
}
