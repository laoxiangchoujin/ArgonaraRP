Shader "Argonara RP/Particles/Unlit"
{
    Properties
    {
        _BaseMap("基础贴图",2D)="white"{}
        _BaseColor("基础颜色",Color) = (1.0, 1.0, 1.0, 1.0)
        
        _Cutoff ("Alpha Cutoff", Range(0.0, 1.0)) = 0.5
        [Toggle(_CLIPPING)]_Clipping("Alpha Clipping",Float) = 0
    	
        [HDR] _EmissionColor("Emission", Color) = (0.0, 0.0, 0.0, 0.0)
        
        [Toggle(_VERTEX_COLORS)] _VertexColors ("Vertex Colors", Float) = 0
    	[Toggle(_FLIPBOOK_BLENDING)]_FlipbookBlending("Flipbook Blending",Float) = 0
        
        [Toggle(_NEAR_FADE)] _NearFade ("Near Fade", Float) = 0
		_NearFadeDistance ("Near Fade Distance", Range(0.0, 10.0)) = 1
		_NearFadeRange ("Near Fade Range", Range(0.01, 10.0)) = 1
    	
    	[Toggle(_SOFT_PARTICLES)]_SoftParticles("Soft Particles",Float) = 0
    	_SoftParticlesDistance("Soft Particles Distance",Range(0.0,10.0)) = 0
    	_SoftParticlesRange("Soft Particles Range",Range(0.01,10.0)) = 1
    	
    	[Toggle(_DISTORTION)] _Distortion ("Distortion", Float) = 0
		[NoScaleOffset] _DistortionMap("Distortion Vectors", 2D) = "bumb" {}
		_DistortionStrength("Distortion Strength", Range(0.0, 0.2)) = 0.1
    	_DistortionBlend("Distortion Blend", Range(0.0, 1.0)) = 1

        
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
            #pragma shader_feature _VERTEX_COLORS//粒子系统的 Start Color、Color over Lifetime 等模块本质上就是给每个粒子/顶点写 COLOR 语义值。
            //unity粒子系统的自定义顶点流可以设置flipbook动画的混合，也就是在两帧之间混合，
            //自定义顶点流，我们选择为baseUV是Texcoord0.xy，额外传uv2为Texcoord0.zw，额外传AnimBlend为Texcoord1.x，这样就能在两帧之间混合为平滑的动画
            #pragma shader_feature _FLIPBOOK_BLENDING
            #pragma shader_feature _NEAR_FADE//靠近相机的粒子，如果renderer有最大粒子大小属性，相机靠太近时会自动移动走。另一个处理靠近的方法如此，算深度，深度太小的，降低alpha值
            #pragma shader_feature _SOFT_PARTICLES
            #pragma shader_feature _DISTORTION
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

		
    }
    CustomEditor "ArgonaraShaderGUI"
}
