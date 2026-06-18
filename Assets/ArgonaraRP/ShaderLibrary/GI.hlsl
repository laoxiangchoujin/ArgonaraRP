#ifndef CUSTOM_GI_INCLUDED
#define CUSTOM_GI_INCLUDED

#if defined(LIGHTMAP_ON)
	#define GI_ATTRIBUTE_DATA				float2 lightMapUV : TEXCOORD1;
	#define GI_VARYINGS_DATA				float2 lightMapUV : VAR_LIGHT_MAP_UV;
#define TRANSFER_GI_DATA(input, output) output.lightMapUV = input.lightMapUV * unity_LightmapST.xy + unity_LightmapST.zw;
	#define GI_FRAGMENT_DATA(input) 		input.lightMapUV
#else
	#define GI_ATTRIBUTE_DATA
	#define GI_VARYINGS_DATA
	#define TRANSFER_GI_DATA(input, output)
	#define GI_FRAGMENT_DATA(input) 0.0
#endif

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/EntityLighting.hlsl"

//光照贴图
TEXTURE2D(unity_Lightmap);
SAMPLER(samplerunity_Lightmap);//还能这样写？

//阴影遮罩贴图
TEXTURE2D(unity_ShadowMask);
SAMPLER(samplerunity_ShadowMask);

//用于LPPV的体积数据
TEXTURE3D_FLOAT(unity_ProbeVolumeSH);
SAMPLER(samplerunity_ProbeVolumeSH);

struct GI
{
	float3 diffuse;
	ShadowMask shadowMask;
};

float3 SampleLightmap(float2 lightMapUV)
{
	#if defined(LIGHTMAP_ON)
	return SampleSingleLightmap(
		TEXTURE2D_ARGS(unity_Lightmap, samplerunity_Lightmap), lightMapUV,
		float4(1.0, 1.0, 0.0, 0.0),//缩放和平移，不用管
		#if defined(UNITY_LIGHTMAP_FULL_HDR)//这个fullHDR若被定义，表示光照贴图未被压缩
			false,
		#else
			true,
		#endif
		float4(LIGHTMAP_HDR_MULTIPLIER, LIGHTMAP_HDR_EXPONENT, 0.0, 0.0)
	);//Core库的函数
	#else
		return 0.0;
	#endif
}

float3 SampleLightProbe(Surface surfaceWS)
{
	#if defined(LIGHTMAP_ON)
		return 0;//静态物体，有光照贴图，就不用光照探针了
	#else
	    if (unity_ProbeVolumeParams.x)//若此值为真，则表示有LPPV数据
	    {
		    return SampleProbeVolumeSH4(TEXTURE3D_ARGS(unity_ProbeVolumeSH, samplerunity_ProbeVolumeSH),
				surfaceWS.position,surfaceWS.normal,
				unity_ProbeVolumeWorldToObject,
				unity_ProbeVolumeParams.y, unity_ProbeVolumeParams.z,
				unity_ProbeVolumeMin.xyz, unity_ProbeVolumeSizeInv.xyz
		    );
	    }
		else
		{
			float4 coefficients[7];
			coefficients[0] = unity_SHAr;
			coefficients[1] = unity_SHAg;
			coefficients[2] = unity_SHAb;
			coefficients[3] = unity_SHBr;
			coefficients[4] = unity_SHBg;
			coefficients[5] = unity_SHBb;
			coefficients[6] = unity_SHC;
			return max(0.0, SampleSH9(coefficients, surfaceWS.normal));
		}
	#endif
}

float4 SampleBakedShadows(float2 lightMapUV, Surface surfaceWS)
{
	#if defined(LIGHTMAP_ON)//虽然是ShadowMask，但要用lightMapUV，所以得看LIGHTMAP_ON
		return SAMPLE_TEXTURE2D(unity_ShadowMask, samplerunity_ShadowMask, lightMapUV);
	#else//动态物体，采样shadow mask用occlusion probe
	    if (unity_ProbeVolumeParams.x){//用occlusion probe proxy volume
	    	return SampleProbeOcclusion(
				TEXTURE3D_ARGS(unity_ProbeVolumeSH, samplerunity_ProbeVolumeSH),
				surfaceWS.position, unity_ProbeVolumeWorldToObject,
				unity_ProbeVolumeParams.y, unity_ProbeVolumeParams.z,
				unity_ProbeVolumeMin.xyz, unity_ProbeVolumeSizeInv.xyz
			);
	    }
		else{
			return unity_ProbesOcclusion;
		}
	#endif
}

GI GetGI(float2 lightMapUV, Surface surfaceWS)
{
	GI gi;
	gi.diffuse = SampleLightmap(lightMapUV) + SampleLightProbe(surfaceWS);
	gi.shadowMask.always = false;
	gi.shadowMask.distance = false;
	gi.shadowMask.shadows = 1.0;
	
	#if defined(_SHADOW_MASK_ALWAYS)
		gi.shadowMask.always = true;
		gi.shadowMask.shadows = SampleBakedShadows(lightMapUV, surfaceWS);
	#elif defined(_SHADOW_MASK_DISTANCE)
		gi.shadowMask.distance = true;
		gi.shadowMask.shadows = SampleBakedShadows(lightMapUV, surfaceWS);
	#endif
	return gi;
}

#endif