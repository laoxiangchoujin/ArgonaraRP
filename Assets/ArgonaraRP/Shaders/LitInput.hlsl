#ifndef CUSTOM_LIT_INPUT_INCLUDED
#define CUSTOM_LIT_INPUT_INCLUDED

TEXTURE2D(_BaseMap);//主贴图
SAMPLER(sampler_BaseMap);
#if defined(_MASK_MAP_NONE)
#elif defined(_MASK_MAP_SINGLE)//数据Mask:单张/多张/没有
	TEXTURE2D(_SingleMaskMap);
	SAMPLER(sampler_SingleMaskMap);
#elif defined(_MASK_MAP_SEPARATE)
	TEXTURE2D(_RoughnessMap);
	SAMPLER(sampler_RoughnessMap);
	TEXTURE2D(_MetallicMap);
	SAMPLER(sampler_MetallicMap);
	TEXTURE2D(_OcclusionMap);
	SAMPLER(sampler_OcclusionMap);
#endif
#if defined(_NORMAL_MAP)
	TEXTURE2D(_NormalMap);//法线
	SAMPLER(sampler_NormalMap);
#endif
#if defined(_DETAIL_MAP)
	TEXTURE2D(_DetailMaskMap);//细节
	SAMPLER(sampler_DetailMaskMap);
	TEXTURE2D(_DetailMap);
	SAMPLER(sampler_DetailMap);
	#if defined(_NORMAL_MAP)
		TEXTURE2D(_DetailNormalMap);
		SAMPLER(sampler_DetailNormalMap);
	#endif
#endif
TEXTURE2D(_EmissionMap);//自发光
SAMPLER(sampler_EmissionMap);


#define INPUT_PROP(name) UNITY_ACCESS_INSTANCED_PROP(UnityPerMaterial, name)

UNITY_INSTANCING_BUFFER_START(UnityPerMaterial)
	UNITY_DEFINE_INSTANCED_PROP(float4, _BaseMap_ST)//图片缩放
	UNITY_DEFINE_INSTANCED_PROP(float4, _DetailMap_ST)
	//UNITY_DEFINE_INSTANCED_PROP(float4, _EmissionMap_ST)
	UNITY_DEFINE_INSTANCED_PROP(float4, _BaseColor)//颜色
	UNITY_DEFINE_INSTANCED_PROP(float4, _EmissionColor)
	UNITY_DEFINE_INSTANCED_PROP(float, _Cutoff)//浮点
	UNITY_DEFINE_INSTANCED_PROP(float, _Roughness)
	UNITY_DEFINE_INSTANCED_PROP(float, _Metallic)
	UNITY_DEFINE_INSTANCED_PROP(float, _Occlusion)
	UNITY_DEFINE_INSTANCED_PROP(float, _NormalScale)
	UNITY_DEFINE_INSTANCED_PROP(float, _DetailAlbedo)
	UNITY_DEFINE_INSTANCED_PROP(float, _DetailRoughness)
	UNITY_DEFINE_INSTANCED_PROP(float, _DetailNormalScale)

	UNITY_DEFINE_INSTANCED_PROP(float, _ZWrite)
UNITY_INSTANCING_BUFFER_END(UnityPerMaterial)

struct InputConfig {
	Fragment fragment;
	float2 baseUV;
	float2 detailUV;
};

InputConfig GetInputConfig (float4 positionSS, float2 baseUV, float2 detailUV = 0.0) {
	InputConfig c;
	c.fragment = GetFragment(positionSS);
	c.baseUV = baseUV;
	c.detailUV = detailUV;
	return c;
}

float2 TransformBaseUV (float2 baseUV) {
	float4 baseST = INPUT_PROP(_BaseMap_ST);
	return baseUV * baseST.xy + baseST.zw;
}

float2 TransformDetailUV (float2 detailUV) {
	float4 detailST = INPUT_PROP(_DetailMap_ST);
	return detailUV * detailST.xy + detailST.zw;
}

float GetDetail (InputConfig c) {
	#if defined(_DETAIL_MAP)
		float map = SAMPLE_TEXTURE2D(_DetailMap, sampler_DetailMap, c.detailUV).r;
		return map * 2.0 - 1.0;//这里，因为对于细节，我们认为0.5是中性，大于0.5是加亮，小于0.5是减暗，故设为+-1范围
	#endif
	
	return 0.0;
}

//细节纹理的Mask遮罩（一般是全0或全1）
float GetDetailMask (InputConfig c) {
	#if defined(_DETAIL_MAP)
		return SAMPLE_TEXTURE2D(_DetailMaskMap, sampler_DetailMaskMap, c.baseUV).r;
	#else
		return 1.0;
	#endif
}

float4 GetBase (InputConfig c) {
	float4 map = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, c.baseUV);
	float4 color = INPUT_PROP(_BaseColor);
	
	#if defined(_DETAIL_MAP)//细节纹理这里只是增强或减弱baseMap颜色，本身不提供颜色
		float detail = GetDetail(c).r * INPUT_PROP(_DetailAlbedo);
		float mask = GetDetailMask(c);
		map.rgb = lerp(sqrt(map.rgb), detail < 0.0 ? 0.0 : 1.0, abs(detail) * mask);
		map.rgb *= map.rgb;//这里先平方根再平方，是为了模拟伽马空间中的修改（计算肯定是在线性空间），让细节导致的变亮和变暗看起来等分布
	#endif
	
	return map * color;
}

float GetCutoff (InputConfig c) {
	return INPUT_PROP(_Cutoff);
}

float GetRoughness (InputConfig c) {
	float roughness = INPUT_PROP(_Roughness);
	#if defined(_MASK_MAP_SINGLE)
		roughness *= SAMPLE_TEXTURE2D(_SingleMaskMap, sampler_SingleMaskMap, c.baseUV).r;
	#elif defined(_MASK_MAP_SEPARATE)
		roughness *= SAMPLE_TEXTURE2D(_RoughnessMap, sampler_RoughnessMap, c.baseUV).r;
	#endif
	
	#if defined(_DETAIL_MAP)
		float detail = GetDetail(c) * INPUT_PROP(_DetailRoughness);
		float mask = GetDetailMask(c).r;
		roughness = lerp(roughness, detail < 0.0 ? 1.0 : 0.0, abs(detail) * mask);
	#endif
	
	return roughness;
}

float GetMetallic (InputConfig c) {
	float metallic = INPUT_PROP(_Metallic);
	#if defined(_MASK_MAP_SINGLE)
		metallic *= SAMPLE_TEXTURE2D(_SingleMaskMap, sampler_SingleMaskMap, c.baseUV).g;
	#elif defined(_MASK_MAP_SEPARATE)
		metallic *= SAMPLE_TEXTURE2D(_MetallicMap, sampler_MetallicMap, c.baseUV).r;
	#endif
	return metallic;
}

float GetOcclusion (InputConfig c) {
	float occlusion = 1.0;
	#if defined(_MASK_MAP_SINGLE)
		occlusion = SAMPLE_TEXTURE2D(_SingleMaskMap, sampler_SingleMaskMap, c.baseUV).b;
	#elif defined(_MASK_MAP_SEPARATE)
		occlusion = SAMPLE_TEXTURE2D(_OcclusionMap, sampler_OcclusionMap, c.baseUV).r;
	#endif
	occlusion = lerp(1.0, occlusion, INPUT_PROP(_Occlusion));
	return occlusion;
}

float3 GetEmission (InputConfig c) {
	#if defined(_EMISSION)
		float4 map = SAMPLE_TEXTURE2D(_EmissionMap, sampler_EmissionMap, c.baseUV);
		float4 color = INPUT_PROP(_EmissionColor);
		return map.rgb * color.rgb;
	#endif
	
	return 0.0;
}

float GetFinalAlpha(float alpha)
{
    return INPUT_PROP(_ZWrite) ? 1.0 : alpha;//ZWrite开启(不透明)则强制Alpha=1，否则保留原始值
}

#if	defined(_NORMAL_MAP)
float3 GetNormalTS (InputConfig c) {
	float4 map = SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, c.baseUV);
	float scale = INPUT_PROP(_NormalScale);
	float3 normal = DecodeNormal(map, scale);
	
	#if defined(_DETAIL_MAP)
		map = SAMPLE_TEXTURE2D(_DetailNormalMap, sampler_DetailNormalMap, c.detailUV);
		scale = INPUT_PROP(_DetailNormalScale) * GetDetailMask(c) * (1 + (GetDetail(c)));
		float3 detail = DecodeNormal(map, scale);
		normal = BlendNormalRNM(normal, detail);//将详细法线围绕基本法线旋转
	#endif
	
	return normal;
}
#endif

#endif
