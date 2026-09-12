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

		//深度法线prepass：屏幕空间阴影/SSAO用。和Lit一致：写**几何法线** + 深度。
		//Unlit的shader里本来没有法线相关的输入/输出，所以这里自带 Attributes/Varyings/顶点函数，
		//fragment 直接复用共用的 DepthNormalsPass.hlsl（它只要求 Varyings 里有 positionCS_SS/baseUV/normalWS）。
		Pass
		{
			Tags{"LightMode" = "DepthNormals"}

			HLSLPROGRAM
			#pragma target 3.5
			#pragma shader_feature _CLIPPING
			#pragma multi_compile _ LOD_FADE_CROSSFADE
			#pragma multi_compile_instancing
			#pragma vertex UnlitDepthNormalsPassVertex
			#pragma fragment DepthNormalsPassFragment

			struct Attributes
			{
				float3 positionOS : POSITION;
				float3 normalOS : NORMAL;
				float2 baseUV : TEXCOORD0;
				UNITY_VERTEX_INPUT_INSTANCE_ID
			};

			struct Varyings
			{
				float4 positionCS_SS : SV_POSITION;
				float3 normalWS : VAR_NORMAL;
				float2 baseUV : VAR_BASE_UV;
				UNITY_VERTEX_INPUT_INSTANCE_ID
			};

			Varyings UnlitDepthNormalsPassVertex (Attributes input)
			{
				Varyings output;
				UNITY_SETUP_INSTANCE_ID(input);
				UNITY_TRANSFER_INSTANCE_ID(input, output);

				float3 positionWS = TransformObjectToWorld(input.positionOS);
				output.positionCS_SS = TransformWorldToHClip(positionWS);
				output.normalWS = TransformObjectToWorldNormal(input.normalOS);
				output.baseUV = TransformBaseUV(input.baseUV);
				return output;
			}

			#include "DepthNormalsPass.hlsl"
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
