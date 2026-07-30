Shader "Argonara RP/Scene/Terrain"
{
    Properties
    {
        _BaseMap("基础贴图", 2D) = "white" {}
		_BaseColor("基础颜色", Color) = (1.0, 1.0, 1.0, 1.0)
		_LodIndex("Lod Index", Float) = 0
        
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

		// 地形参数（C# 传入）
		[HideInInspector] _HeightMap("Height Map", 2D) = "white" {}
		[HideInInspector] _TerrainWidth("Terrain Width", Float) = 1024
		[HideInInspector] _TerrainMaxHeight("Terrain Max Height", Float) = 512
		//[HideInInspector] _NormalMap("Terrain Normal Map", 2D) = "bump" {}
    }
    SubShader
    {
        HLSLINCLUDE
		#define UNITY_PROCEDURAL_INSTANCING_ENABLED
		#define UNITY_INSTANCING_PROCEDURAL_FUNC ProceduralSetup
		#include"../../ShaderLibrary/Common.hlsl"
		#include"../LitInput.hlsl"

		// GPU InstancedIndirect 数据
		struct InstanceData
		{
			float3 pos;
			float3 rot;
			float sca;
		};
		StructuredBuffer<InstanceData> afterCulling;
		float4x4 _ProceduralMatrix;

		float4x4 BuildTRSMatrix(float3 pos, float3 rot, float scale)
		{
			float3 r = radians(rot);
			float cx = cos(r.x); float sx = sin(r.x);
			float cy = cos(r.y); float sy = sin(r.y);
			float cz = cos(r.z); float sz = sin(r.z);
			float3 right = float3(
				cy*cz + sx*sy*sz, cx*sz, -cz*sy + cy*sx*sz);
			float3 up = float3(
				-cy*sz + cz*sx*sy, cx*cz, sy*sz + cy*cz*sx);
			float3 forward = float3(cx*sy, -sx, cx*cy);
			return float4x4(
				right.x*scale, up.x*scale, forward.x*scale, pos.x,
				right.y*scale, up.y*scale, forward.y*scale, pos.y,
				right.z*scale, up.z*scale, forward.z*scale, pos.z,
				0, 0, 0, 1);
		}

		// GPU 在每实例绘制前调用此函数，unity_InstanceID 由硬件提供
		void ProceduralSetup()
		{
			InstanceData inst = afterCulling[unity_InstanceID];
			_ProceduralMatrix = BuildTRSMatrix(inst.pos, inst.rot, inst.sca );
		}
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
            #include "../LitPass.hlsl"
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
			#include "../ShadowCasterPass.hlsl"
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
			#include "../MetaPass.hlsl"
			ENDHLSL
		}

		//Deferred GBuffer Pass
		//针对Opaque Lit物体，把数据写入GBuffer的多张GT中，等待CameraRenderer的"Deferred Lighting" pass计算光照
		Pass
        {
            Tags {"LightMode" = "ArgonaraGBuffer"}
            Blend Off
            ZWrite On
            
            HLSLPROGRAM
            #pragma target 3.5

			#pragma instancing_options procedural:ProceduralSetup
			#pragma multi_compile _ _USE_DEBUG
            
            #pragma shader_feature _CLIPPING
            #pragma shader_feature _PREMULTIPLY_ALPHA
            #pragma multi_compile _ LIGHTMAP_ON
            #pragma multi_compile _ LOD_FADE_CROSSFADE
            #pragma shader_feature _NORMAL_MAP
            #pragma shader_feature _MASK_MAP_NONE _MASK_MAP_SINGLE _MASK_MAP_SEPARATE
            #pragma shader_feature _EMISSION
            #pragma shader_feature _DETAIL_MAP
            #pragma multi_compile_instancing
            #pragma vertex TerrainGBufferVert
            #pragma fragment TerrainGBufferFrag
            #include "../LitPass.hlsl"
            
            int _LodIndex;
            float _TerrainWidth;
            float _TerrainMaxHeight;
            
            TEXTURE2D(_HeightMap);
            float4 _HeightMap_ST;;

			Varyings TerrainGBufferVert(Attributes input)
			{
				Varyings output;
				UNITY_SETUP_INSTANCE_ID(input);
				UNITY_TRANSFER_INSTANCE_ID(input, output);
				TRANSFER_GI_DATA(input, output);

				float3 posWS = mul(_ProceduralMatrix, float4(input.positionOS, 1.0)).xyz;

				// 高度图采样
				float2 tu = float2(
					(posWS.x + _TerrainWidth * 0.5) / _TerrainWidth,
					(posWS.z + _TerrainWidth * 0.5) / _TerrainWidth);
				float h = SAMPLE_TEXTURE2D_LOD(_HeightMap, sampler_point_clamp,
					tu * _HeightMap_ST.xy + _HeightMap_ST.zw, 0);
				posWS.y += h * _TerrainMaxHeight;

				output.positionWS = posWS;
				output.positionCS_SS = TransformWorldToHClip(posWS);
				output.normalWS = float3(0,1,0);
				output.baseUV = TransformBaseUV(input.baseUV);
				#if defined(_NORMAL_MAP)
					output.tangentWS = float4(
						normalize(mul((float3x3)_ProceduralMatrix, input.tangentOS.xyz)),
						input.tangentOS.w);
				#endif
				#if defined(_DETAIL_MAP)
					output.detailUV = TransformDetailUV(input.baseUV);
				#endif
				return output;
			}

			float4 GetLodDebugColor(float lod)
			{
				float3 cols[8] = {
					float3(1,0,0), float3(1,0.5,0), float3(1,1,0), float3(0,1,0),
					float3(0,1,1), float3(0,0,1), float3(0.5,0,1), float3(1,0,1)
				};
				return float4(cols[clamp((int)lod, 0, 7)], 1);
			}

			void TerrainGBufferFrag(Varyings input,
				out float4 GT1 : SV_Target0,
				out float4 GT2 : SV_Target1,
				out float4 GT3 : SV_Target2,
				out float3 GT4 : SV_Target3)
			{
				UNITY_SETUP_INSTANCE_ID(input);

				InputConfig config = GetInputConfig(input.positionCS_SS, input.baseUV);
				ClipLOD(config.fragment, unity_LODFade.x);
				#if defined(_DETAIL_MAP)
					config.detailUV = input.detailUV;
				#endif

				float4 base = GetBase(config);
				#if defined(_CLIPPING)
					clip(base.a - GetCutoff(config));
				#endif

				float3 color = base.rgb;
				#if _USE_DEBUG
					color *= GetLodDebugColor(_LodIndex).rgb;
				#endif

				Surface surfaceWS;
				surfaceWS.position = input.positionWS;
				#if defined(_NORMAL_MAP)
					surfaceWS.normal = normalize(NormalTangentToWorld(GetNormalTS(config), input.normalWS, input.tangentWS));
					surfaceWS.interpolatedNormal = normalize(input.normalWS);
				#else
					surfaceWS.normal = normalize(input.normalWS);
					surfaceWS.interpolatedNormal = surfaceWS.normal;
				#endif
				surfaceWS.viewDirection = normalize(_WorldSpaceCameraPos - input.positionWS);
				surfaceWS.depth = -TransformWorldToView(input.positionWS).z;
				surfaceWS.albedo = base.rgb;
				surfaceWS.alpha = 1;
				surfaceWS.metallic = GetMetallic(config);
				surfaceWS.occlusion = GetOcclusion(config);
				surfaceWS.roughness = GetRoughness(config);
				surfaceWS.dither = InterleavedGradientNoise(config.fragment.positionSS, 0);
				surfaceWS.renderingLayerMask = asuint(unity_RenderingLayer.x);

				BRDF brdf = GetBRDF(surfaceWS, false);
				GI gi = GetGI(GI_FRAGMENT_DATA(input), surfaceWS, brdf);
				float3 emission = GetEmission(config);
				float3 indirectColor = IndirectBRDF(surfaceWS, brdf, gi.diffuse, gi.specular);

				float shadingModelID4_null4 = ((uint)1 << 4) / 255.0;
				color = GetLodDebugColor(_LodIndex).rgb;
				GT1 = float4(color, shadingModelID4_null4);
				GT2 = float4(surfaceWS.normal * 0.5 + 0.5, 0.0);
				GT3 = float4(surfaceWS.roughness, surfaceWS.metallic, surfaceWS.occlusion, 0.0);
				GT4 = float3(emission + indirectColor);
			}
            ENDHLSL
        }
    }
    CustomEditor "ArgonaraShaderGUI"//双引号里填这个ShaderGUI的类名就可，unity会自动搜索叫这个名字且继承了ShaderGUI类的class来重绘inspector
}
