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
//声明放在GI.hlsl而不是ScreenSpaceReflection.hlsl：所有走间接高光的shader（Lit/GPUDrivenTerrain/那个全屏shader）
//都要用它，而这些shader都include了GI.hlsl ⇒ 放这最省事，也避免重复声明
TEXTURE2D(_SSRTex);
//本帧有没有**可用的**SSR图（1=有）。由延迟渲染器每帧上传，它其实管两件互补的事：
//  ① 下面带UV的那个 SampleEnvironment 变体：要不要去采 _SSRTex 做替换（为0时连采样都不做）；
//  ② 写GBuffer那一趟（延迟的 GT4）：1 = "高光改由SSR生成之后的全屏合成pass补"，
//     所以 GT4 里**只写** emission + 间接漫反射（写入端读这个值是"取反"用的）；0 = 老路，GT4 里含高光。
//两者在当前设计下永远互补（开SSR ⇔ 有图 ⇔ GT4不写高光），所以一个变量就够。
//名字描述的是"SSR可不可用"这个本源含义，"GT4里有没有高光"只是它的推论。
//（它只管延迟那一套：GBuffer的GT4写法 + 延迟的合成pass。前向用的是下面那个同名的 forward 版）
int _UseScreenSpaceReflectionInDeferred;

//前向版的"本帧有没有可用的SSR图"（1=有）：前向的 SSR 只能用**上一帧**的图（本帧的物体在
//trace/拷贝之前就画完了），所以它和延迟那套不能共用一个 uniform；由前向渲染器每帧上传。
//两个渲染器各自设自己那个、共用下面同一个 SampleEnvironment 变体（条件里是"或"）。
int _UseScreenSpaceReflectionInForward;
//SSR反射的亮度倍率（当gain用）：0 = 反射全黑，1 = 原样，>1 = 更亮。
//只乘"反射颜色"，**不碰可信度a**（要不要用SSR由 a 和 _UseScreenSpaceReflectionInDeferred 决定）。
//半分辨率+模糊会把高光峰值摊平，觉得暗就用它补一点。
//只有 _UseScreenSpaceReflectionInDeferred > 0（SSR图有效）时才用得上
float _SSRIntensity;

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

//带屏幕UV的变体：比上面多一步"用SSR的反射替换环境反射"。
//屏幕UV由调用方给（全屏合成pass是quad，物体pass也有自己的屏幕UV，都很好拿），所以这函数自己不去反算UV。
//⚠️ 这里只混**原始入射高光**：Fresnel/F0 那套权重是在 IndirectBRDF 的 IndirSpecFactor 里统一乘的，
//   要是这里再乘一次 Fresnel，掠射角会明显变暗（双重加权）
//⚠️ 没开SSR时（_SSRTex 那张图没生成）直接返回环境反射，和以前逐像素完全一致（连采样都不做）
float3 SampleEnvironment (Surface surfaceWS, BRDF brdf, float2 screenUV) {
	float3 environment = SampleEnvironment(surfaceWS, brdf);
	//"或"：延迟（本帧追、本帧合成）和前向（上一帧的图）各自设自己那个开关
	if (_UseScreenSpaceReflectionInDeferred > 0 || _UseScreenSpaceReflectionInForward > 0) {
		float4 ssr = SAMPLE_TEXTURE2D_LOD(_SSRTex, sampler_linear_clamp, screenUV, 0);
		//ssr.a 是 alphaCalc 算出来的可信度：没命中/太靠边缘/太远 = 0 → 保留环境反射
		//_SSRIntensity 只乘反射颜色（gain），不碰可信度
		ssr.rgb *= _SSRIntensity;
		environment = lerp(environment, ssr.rgb, saturate(ssr.a));
	}
	return environment;
}

GI GetGI(float2 lightMapUV, Surface surfaceWS, BRDF brdf)
{
	GI gi;
	gi.diffuse = SampleLightmap(lightMapUV) + SampleLightProbe(surfaceWS);
	gi.specular = SampleEnvironment(surfaceWS, brdf);
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