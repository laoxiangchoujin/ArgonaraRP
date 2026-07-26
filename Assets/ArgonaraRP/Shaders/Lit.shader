Shader "Argonara RP/Lit"
{
    Properties
    {
        _BaseMap("基础贴图", 2D) = "white" {}
		_BaseColor("基础颜色", Color) = (1.0, 1.0, 1.0, 1.0)
        
        _Cutoff ("Alpha Cutoff", Range(0.0, 1.0)) = 0.5
        [Toggle(_CLIPPING)]_Clipping("Alpha Clipping",Float) = 0
        
    	_Metallic ("Metallic", Range(0, 1)) = 0
    	_Occlusion ("Occlusion", Range(0, 1)) = 1
		_Smoothness ("Smoothness", Range(0, 1)) = 0.5
    	//_Fresnel ("Fresnel", Range(0, 1)) = 1
    	
    	
    	[Toggle(_MASK_MAP)] _MaskMapToggle ("Mask Map", Float) = 0
    	[NoScaleOffset] _MaskMap("Mask (MODS)", 2D) = "white" {}
    	
    	[Toggle(_NORMAL_MAP)] _NormalMapToggle ("Normal Map", Float) = 0
    	[NoScaleOffset]_NormalMap("Normals",2D) = "bump"{}
    	_NormalScale("Normal Scale",Range(0,1)) = 1
    	
    	[Toggle(_DETAIL_MAP)] _DetailMapToggle ("Detail Maps", Float) = 0
    	_DetailMap("Details Map", 2D) = "linearGrey" {}
    	_DetailNormalMap("Detail Normals",2D)="bump"{}
    	_DetailAlbedo("Detail Albedo", Range(0, 1)) = 1
    	_DetailSmoothness("Detail Smoothness", Range(0, 1)) = 1
    	_DetailNormalScale("Detail Normal Scale",Range(0,1)) = 1
    	
    	
    	[NoScaleOffset] _EmissionMap("Emission Map", 2D) = "white" {}//因为不需要单独给这个tex弄scale和offset，它可以服用basemap的
		[HDR] _EmissionColor("Emission", Color) = (0.0, 0.0, 0.0, 0.0)
    	
    	//---------------以下是设置-----------------//
    	
        [Toggle(_PREMULTIPLY_ALPHA)]_PremulAlpha("Premultiply Alpha（如果是玻璃，启用它，并且One,OneMinusSrcAlpha）",Float)=0
        
        [Enum(UnityEngine.Rendering.BlendMode)]_SrcBlend("Src Blend",Float) = 5
        [Enum(UnityEngine.Rendering.BlendMode)]_DstBlend("Dst Blend",Float) = 8
        
        [Enum(Off,0,On,1)]_ZWrite("Z Write",Float) = 1
    	
    	[KeywordEnum(On, Clip, Dither, Off)]_Shadows("Cast Shadows Mode",Float)=0
    	
    	[Toggle(_RECEIVE_SHADOWS)] _ReceiveShadows ("Receive Shadows", Float) = 1
    	
    	
    	
    	//很奇怪的做法，不去改上边的（）
    	//烘焙光照时，Unity 的light mapper对透明度有一种固定的处理方式。它会查看材质的队列来确定它是不透明的、裁剪的还是透明的。
    	//然后，它通过将 _MainTex 和 _Color 属性的 alpha相乘来确定透明度，使用 _Cutoff 属性进行 alpha 裁剪,一定得是这三个名字,对此unity不看shader逻辑，只看这几个材质属性
    	[HideInInspector] _MainTex("Texture for Lightmap", 2D) = "white" {}
		[HideInInspector] _Color("Color for Lightmap", Color) = (0.5, 0.5, 0.5, 1.0)
    	//另外，虽然可能可以在 MetaPassFragment 中裁剪片段，但不需要这样做，因为透明度是单独处理的
    }
    SubShader
    {
		HLSLINCLUDE
		#include"../ShaderLibrary/Common.hlsl"
		#include"LitInput.hlsl"
    	ENDHLSL
        Pass
        {
            Tags {"LightMode" = "ArgonaraLit"}
            Blend [_SrcBlend] [_DstBlend], One OneMinusSrcAlpha//对透明度额外设置固定的预乘混合模式，这是Alpha合成的标准"over"算子。只有这个公式能保证不管绘制顺序，最终累积的 Alpha 始终 ≤1 且逻辑正确
            ZWrite [_ZWrite]
            
            HLSLPROGRAM
            #pragma target 3.5//避免在OpenGL ES 2.0和WebGL 1.0编译这些shader（因为不支持循环）
            
            #pragma shader_feature _CLIPPING
            #pragma shader_feature _PREMULTIPLY_ALPHA
            #pragma multi_compile _ _DIRECTIONAL_PCF3 _DIRECTIONAL_PCF5 _DIRECTIONAL_PCF7//只有一个_的是没有这些关键字，也就是pcf2x2
            #pragma multi_compile _ _CASCADE_BLEND_SOFT _CASCADE_BLEND_DITHER
            #pragma shader_feature _RECEIVE_SHADOWS
            #pragma multi_compile _ LIGHTMAP_ON//不是_LIGHTMAP_ON？
            #pragma multi_compile _ _SHADOW_MASK_ALWAYS _SHADOW_MASK_DISTANCE
            #pragma multi_compile _ LOD_FADE_CROSSFADE
            #pragma shader_feature _NORMAL_MAP
            #pragma shader_feature _MASK_MAP
            #pragma shader_feature _DETAIL_MAP
            #pragma multi_compile _ _LIGHTS_PER_OBJECT//针对点光源或聚光灯的逐物体光照
            #pragma multi_compile _ _OTHER_PCF3 _OTHER_PCF5 _OTHER_PCF7
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
			#pragma multi_compile _ LOD_FADE_CROSSFADE
			#pragma multi_compile_instancing
			#pragma vertex ShadowCasterPassVertex
			#pragma fragment ShadowCasterPassFragment
			#include "ShadowCasterPass.hlsl"
			ENDHLSL
        }

		Pass
		{
			Tags{"LightMode" = "Meta"}
			Cull Off//Meta Pass要关闭Cull
			
			HLSLPROGRAM
			#pragma target 3.5
			#pragma vertex MetaPassVertex
			#pragma fragment MetaPassFragment
			#include "MetaPass.hlsl"
			ENDHLSL
		}

		//Deferred GBuffer Pass
		//针对Opaque Lit物体，把数据写入GBuffer的多张GT中，等待CameraRenderer的"Deferred Lighting" pass计算光照
		Pass
        {
            Tags {"LightMode" = "ArgonaraGBuffer"}
            Blend Off//GBuffer数据禁止混合，若混合则会污染GT
            ZWrite On
            
            HLSLPROGRAM
            #pragma target 3.5
            
            #pragma shader_feature _CLIPPING
            #pragma shader_feature _PREMULTIPLY_ALPHA
            #pragma multi_compile _ LIGHTMAP_ON//不是_LIGHTMAP_ON？
            #pragma multi_compile _ LOD_FADE_CROSSFADE
            #pragma shader_feature _NORMAL_MAP
            #pragma shader_feature _MASK_MAP
            #pragma shader_feature _DETAIL_MAP
            #pragma multi_compile_instancing
            #pragma vertex LitPassVertex
            #pragma fragment LitPassFragmentGBuffer
            #include "LitPass.hlsl"
            ENDHLSL
        }
    }
    CustomEditor "ArgonaraShaderGUI"//双引号里填这个ShaderGUI的类名就可，unity会自动搜索叫这个名字且继承了ShaderGUI类的class来重绘inspector
}
