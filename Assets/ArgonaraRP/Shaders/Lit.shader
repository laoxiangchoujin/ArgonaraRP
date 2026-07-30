Shader "Argonara RP/Lit"
{
    Properties
    {
        _BaseMap("基础贴图", 2D) = "white" {}
		_BaseColor("基础颜色", Color) = (1.0, 1.0, 1.0, 1.0)
        
        [Toggle(_CLIPPING)]_Clipping("Alpha Clipping",Float) = 0
    	_Cutoff ("Alpha Cutoff", Range(0.0, 1.0)) = 0.5
        
    	[KeywordEnum(None, Single, Separate)] _Mask_Map ("Mask Map", Float) = 0
	    [NoScaleOffset] _SingleMaskMap("Single Mask (RMO)", 2D) = "white" {}
    	[NoScaleOffset] _RoughnessMap("Roughness Map", 2D) = "white" {}
    	[NoScaleOffset] _MetallicMap("Metallic Map", 2D) = "white" {}
    	[NoScaleOffset] _OcclusionMap("Occlusion Map", 2D) = "white" {}
    	//
    	_Metallic ("Metallic", Range(0, 1)) = 0
    	_Occlusion ("Occlusion", Range(0, 1)) = 1
		_Roughness ("Roughness", Range(0, 1)) = 0.5
    	
    	[Toggle(_NORMAL_MAP)] _NormalMapToggle ("Normal", Float) = 0
    	[NoScaleOffset] _NormalMap("Normal Map",2D) = "bump"{}
    	_NormalScale("Normal Scale",Range(0,2)) = 1
    	
    	[Toggle(_DETAIL_MAP)] _DetailMapToggle ("Detail", Float) = 0
    	[NoScaleOffset] _DetailMaskMap("Detail Mask(same uv with baseMap)", 2D) = "white" {}
    	_DetailMap("Detail Map", 2D) = "linearGrey" {}
    	[NoScaleOffset] _DetailNormalMap("Detail Normal",2D)="bump"{}
    	_DetailAlbedo("Detail Albedo", Range(0, 1)) = 1
    	_DetailRoughness("Detail Roughness", Range(0, 1)) = 1
    	_DetailNormalScale("Detail Normal Scale",Range(0,2)) = 1
        
    	[Toggle(_EMISSION)] _EmissionToggle ("Emission", Float) = 0
    	[NoScaleOffset] _EmissionMap("Emission Map", 2D) = "white" {}//因为不需要单独给这个tex弄scale和offset，它可以服用basemap的
		[HDR] _EmissionColor("Emission Color", Color) = (0.0, 0.0, 0.0, 0.0)
    	
    	//---------------以下是设置-----------------//
    	//深度和阴影
    	[Enum(Off,0,On,1)]_ZWrite("Z Write",Float) = 1
    	[KeywordEnum(On, Clip, Dither, Off)]_Shadows("Cast Shadows Mode",Float)=0
    	[Toggle(_RECEIVE_SHADOWS)] _ReceiveShadows ("Receive Shadows", Float) = 1
    	//半透
        [Toggle(_PREMULTIPLY_ALPHA)]_PremulAlpha("Premultiply Alpha（如果是玻璃，启用它，并且One,OneMinusSrcAlpha）",Float)=0
        [Enum(UnityEngine.Rendering.BlendMode)]_SrcBlend("Src Blend",Float) = 5
        [Enum(UnityEngine.Rendering.BlendMode)]_DstBlend("Dst Blend",Float) = 8
    	//模板
    	_StencilRef("Stencil Reference", Float) = 0
    	[Enum(UnityEngine.Rendering.CompareFunction)]_StencilComp("Stencil Comparison", Float) = 8
    	[Enum(UnityEngine.Rendering.StencilOp)]_StencilOp("Stencil Operation", Float) = 0
    	
    	
    	
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

        Stencil
        {
            Ref [_StencilRef]
            Comp [_StencilComp]
            Pass [_StencilOp]
        }

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
            #pragma shader_feature _MASK_MAP_NONE _MASK_MAP_SINGLE _MASK_MAP_SEPARATE
            #pragma shader_feature _EMISSION
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
			#pragma shader_feature _MASK_MAP_NONE _MASK_MAP_SINGLE _MASK_MAP_SEPARATE
			#pragma shader_feature _DETAIL_MAP
			#pragma shader_feature _EMISSION
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
            #pragma shader_feature _MASK_MAP_NONE _MASK_MAP_SINGLE _MASK_MAP_SEPARATE
            #pragma shader_feature _EMISSION
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
