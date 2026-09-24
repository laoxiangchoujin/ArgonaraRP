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
	#define GI_FRAGMENT_DATA(input) float2(0.0, 0.0)
#endif

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/EntityLighting.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/ImageBasedLighting.hlsl"

//光照贴图
TEXTURE2D(unity_Lightmap);
SAMPLER(samplerunity_Lightmap);//还能这样写？

//阴影遮罩贴图
TEXTURE2D(unity_ShadowMask);
SAMPLER(samplerunity_ShadowMask);

//用于LPPV的体积数据
TEXTURE3D_FLOAT(unity_ProbeVolumeSH);
SAMPLER(samplerunity_ProbeVolumeSH);

//镜面反射，默认是天空盒，若附近有合适的反射探针reflection probe，那就是探针的反射Cubemap
TEXTURECUBE(unity_SpecCube0);
SAMPLER(samplerunity_SpecCube0);

//屏幕空间反射（SSR）的反射图：rgb = 反射色、a = 这次命中的可信度（0 = 没命中，用回环境反射）。
//声明放在GI.hlsl而不是ScreenSpaceReflection.hlsl：所有走间接高光的shader（Lit/GPUDrivenTerrain）
//都要用它，而这些shader都include了GI.hlsl ⇒ 放这最省事，也避免重复声明。
//**两条路（前向/延迟）都是"本帧追、下一帧用"**：渲染器每帧把这张图绑成"上一帧追出来的那张"；
//没开SSR时绑的是 **1×1 纯黑**（a = 0 ⇒ 下面 lerp 的权重是 0）⇒ 自动退回环境反射，所以不需要任何开关 uniform。
TEXTURE2D(_SSRTex);
//SSR反射的亮度倍率（当gain用）：0 = 反射全黑，1 = 原样，>1 = 更亮。
//只乘"反射颜色"，**不碰可信度a**（"采不采SSR"由 a 决定：a = 0 就是没有）。
//半分辨率+模糊会把高光峰值摊平，觉得暗就用它补一点
float _SSRIntensity;

//屏幕空间间接漫反射（SSGI）的 GI 图：**rgb = 间接漫反射的辐照度**（和 SampleLightProbe 同口径、屏幕空间结果与SH兜底已混好；
//⚠️ 别在里面乘"接收点"的 albedo —— 外层 IndirectBRDF 还会乘 k_d × albedo）、a = 可信度（0 = 完全别信它）。
//声明放这和 _SSRTex 同理：所有走间接光的 shader 都 include 了 GI.hlsl。
//**没开 SSGI 或没接 SSGI 的路径（前向）由渲染器绑 1×1 纯黑**（a = 0 ⇒ 下面 lerp 的权重是 0）⇒ 自动退回烘焙，
//所以同样不需要任何开关 uniform。
TEXTURE2D(_SSGITex);
//间接漫反射的亮度倍率：只乘 GI 颜色，不碰可信度 a
float _SSGIIntensity;

struct GI
{
	float3 diffuse;
	float3 specular;
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

float3 SampleLightProbe(float3 positionWS, float3 normalWS)
{
	#if defined(LIGHTMAP_ON)
	return 0;//静态物体，有光照贴图，就不用光照探针了
	#else
	if (unity_ProbeVolumeParams.x)//若此值为真，则表示有LPPV数据
	{
		return SampleProbeVolumeSH4(TEXTURE3D_ARGS(unity_ProbeVolumeSH, samplerunity_ProbeVolumeSH),
			positionWS,normalWS,
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
		return max(0.0, SampleSH9(coefficients, normalWS));
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

float3 SampleEnvironment (Surface surfaceWS, BRDF brdf) {
	float3 uvw = reflect(-surfaceWS.viewDirection, surfaceWS.normal);
	
	float mip = PerceptualRoughnessToMipmapLevel(brdf.perceptualRoughness);
	float4 environment = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, uvw, mip);
	return DecodeHDREnvironment(environment, unity_SpecCube0_HDR);;
}

//带屏幕UV的变体：比上面多一步"用SSR的反射**替换**环境反射"（按可信度 a 做 lerp，a=0 就是纯环境反射）。
//屏幕UV由调用方给（物体pass有自己的屏幕UV，很好拿），所以这函数自己不去反算UV。
//⚠️ 这里只混**原始入射高光**：Fresnel/F0 那套权重是在 IndirectBRDF 的 IndirSpecFactor 里统一乘的，
//   要是这里再乘一次 Fresnel，掠射角会明显变暗（双重加权）
//⚠️ 没有开关 uniform：没开SSR时渲染器绑的是 1×1 纯黑（a = 0）⇒ 结果逐像素等于纯环境反射
float3 SampleEnvironment (Surface surfaceWS, BRDF brdf, float2 screenUV) {
	float3 environment = SampleEnvironment(surfaceWS, brdf);
	float4 ssr = SAMPLE_TEXTURE2D_LOD(_SSRTex, sampler_linear_clamp, screenUV, 0);
	//ssr.a 是 alphaCalc 算出来的可信度：没命中/太靠边缘/太远 = 0 → 保留环境反射
	//_SSRIntensity 只乘反射颜色（gain），不碰可信度
	ssr.rgb *= _SSRIntensity;
	return lerp(environment, ssr.rgb, saturate(ssr.a));
}

//screenUV：间接高光要用它去采"上一帧的SSR图"（环境反射与SSR在这里按可信度a混好）；间接漫反射也用它采"上一帧的SSGI图"
//⇒ 调用方拿到 gi 之后**不用**再动 gi.specular（免得两处各算一遍）
GI GetGI(float2 lightMapUV, Surface surfaceWS, BRDF brdf, float2 screenUV)
{
	GI gi;
	float3 baked = SampleLightmap(lightMapUV) + SampleLightProbe(surfaceWS);
	//屏幕空间间接漫反射（SSGI）：按可信度 a 与烘焙结果加权。
	//a = 0（没开 SSGI / 这条路径没接 / 没追到 / 屏幕边缘）⇒ 逐像素等于纯烘焙结果，所以不需要开关 uniform。
	//⚠️ _SSGITex 是半分辨率的：双线性采样顺便当上采样（前景高频会串一点色，以后可换深度/法线引导的上采样）
	float4 ssgi = SAMPLE_TEXTURE2D_LOD(_SSGITex, sampler_linear_clamp, screenUV, 0);
	ssgi.rgb *= _SSGIIntensity;
	gi.diffuse = lerp(baked, ssgi.rgb, saturate(ssgi.a));
	gi.specular = SampleEnvironment(surfaceWS, brdf, screenUV);
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

// GI GetGI(float3 precomputedIndirectDiffuse, Surface surfaceWS, BRDF brdf)
// {
// 	GI gi;
// 	gi.diffuse = precomputedIndirectDiffuse;
// 	gi.specular = SampleEnvironment(surfaceWS, brdf);
// 	gi.shadowMask.always = false;
// 	gi.shadowMask.distance = false;
// 	gi.shadowMask.shadows = 1.0;
// 	
// 	// #if defined(_SHADOW_MASK_ALWAYS)
// 	// gi.shadowMask.always = true;
// 	// gi.shadowMask.shadows = SampleBakedShadows(lightMapUV, surfaceWS);
// 	// #elif defined(_SHADOW_MASK_DISTANCE)
// 	// gi.shadowMask.distance = true;
// 	// gi.shadowMask.shadows = SampleBakedShadows(lightMapUV, surfaceWS);
// 	// #endif
// 	return gi;
// }

#endif