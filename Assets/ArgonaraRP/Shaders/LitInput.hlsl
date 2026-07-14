#ifndef CUSTOM_LIT_INPUT_INCLUDED
#define CUSTOM_LIT_INPUT_INCLUDED

TEXTURE2D(_BaseMap);
SAMPLER(sampler_BaseMap);
TEXTURE2D(_MaskMap);
SAMPLER(sampler_MaskMap);
TEXTURE2D(_NormalMap);
SAMPLER(sampler_NormalMap);
TEXTURE2D(_DetailNormalMap);
SAMPLER(sampler_DetailNormalMap);
TEXTURE2D(_DetailMap);
SAMPLER(sampler_DetailMap);
TEXTURE2D(_EmissionMap);
SAMPLER(sampler_EmissionMap);


#define INPUT_PROP(name) UNITY_ACCESS_INSTANCED_PROP(UnityPerMaterial, name)

UNITY_INSTANCING_BUFFER_START(UnityPerMaterial)
	UNITY_DEFINE_INSTANCED_PROP(float4, _BaseMap_ST)
	UNITY_DEFINE_INSTANCED_PROP(float4, _DetailMap_ST)
	UNITY_DEFINE_INSTANCED_PROP(float4, _BaseColor)
	UNITY_DEFINE_INSTANCED_PROP(float4, _EmissionColor)
	UNITY_DEFINE_INSTANCED_PROP(float, _Cutoff)
	UNITY_DEFINE_INSTANCED_PROP(float, _Metallic)
	UNITY_DEFINE_INSTANCED_PROP(float, _Occlusion)
	UNITY_DEFINE_INSTANCED_PROP(float, _DetailAlbedo)
	UNITY_DEFINE_INSTANCED_PROP(float, _DetailSmoothness)
	UNITY_DEFINE_INSTANCED_PROP(float, _DetailNormalScale)
	UNITY_DEFINE_INSTANCED_PROP(float, _NormalScale)
	UNITY_DEFINE_INSTANCED_PROP(float, _Smoothness)
	UNITY_DEFINE_INSTANCED_PROP(float, _Fresnel)
	UNITY_DEFINE_INSTANCED_PROP(float, _ZWrite)
UNITY_INSTANCING_BUFFER_END(UnityPerMaterial)

struct InputConfig {
	Fragment fragment;
	float2 baseUV;
	float2 detailUV;
	bool useMask;
	bool useDetail;
};

InputConfig GetInputConfig (float4 positionSS, float2 baseUV, float2 detailUV = 0.0) {
	InputConfig c;
	c.fragment = GetFragment(positionSS);
	c.baseUV = baseUV;
	c.detailUV = detailUV;
	c.useMask = false;
	c.useDetail = false;
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

float4 GetDetail (InputConfig c) {
	if (c.useDetail) {
		float4 map = SAMPLE_TEXTURE2D(_DetailMap, sampler_DetailMap, c.detailUV);
		return map * 2.0 - 1.0;//这里，因为对于细节，我们认为0.5是中性，大于0.5是加亮，小于0.5是减暗，故设为+-1范围
	}
	return 0.0;
}

float4 GetMask (InputConfig c) {
	if (c.useMask) {
		return SAMPLE_TEXTURE2D(_MaskMap, sampler_MaskMap, c.baseUV);
	}
	return 1.0;
}

float4 GetBase (InputConfig c) {
	float4 map = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, c.baseUV);
	float4 color = INPUT_PROP(_BaseColor);
	
	if (c.useDetail) {
		float detail = GetDetail(c).r * INPUT_PROP(_DetailAlbedo);
		float mask = GetMask(c).b;
		map.rgb = lerp(sqrt(map.rgb), detail < 0.0 ? 0.0 : 1.0, abs(detail) * mask);
		map.rgb *= map.rgb;//这里先平方根再平方，是为了模拟伽马空间中的修改（计算肯定是在线性空间），让细节导致的变亮和变暗看起来等分布
	}
	
	return map * color;
}

float GetCutoff (InputConfig c) {
	return INPUT_PROP(_Cutoff);
}

float GetMetallic (InputConfig c) {
	float metallic = INPUT_PROP(_Metallic);
	metallic *= GetMask(c).r;
	return metallic;
}

float GetOcclusion (InputConfig c) {
	float strength = INPUT_PROP(_Occlusion);
	float occlusion = GetMask(c).g;
	occlusion = lerp(1.0, occlusion, strength);
	return occlusion;
}

float GetSmoothness (InputConfig c) {
	float smoothness = INPUT_PROP(_Smoothness);
	smoothness *= GetMask(c).a;
	
	if (c.useDetail)
	{
		float detail = GetDetail(c).b * INPUT_PROP(_DetailSmoothness);
		float mask = GetMask(c).b;
		smoothness = lerp(smoothness, detail < 0.0 ? 0.0 : 1.0, abs(detail) * mask);
	}
		
	return smoothness;
}

float3 GetEmission (InputConfig c) {
	float4 map = SAMPLE_TEXTURE2D(_EmissionMap, sampler_EmissionMap, c.baseUV);
	float4 color = INPUT_PROP(_EmissionColor);
	return map.rgb * color.rgb;
}

float GetFresnel (InputConfig c) {
	return INPUT_PROP(_Fresnel);
}

float GetFinalAlpha(float alpha)
{
    return INPUT_PROP(_ZWrite) ? 1.0 : alpha;//ZWrite开启(不透明)则强制Alpha=1，否则保留原始值
}

float3 GetNormalTS (InputConfig c) {
	float4 map = SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, c.baseUV);
	float scale = INPUT_PROP(_NormalScale);
	float3 normal = DecodeNormal(map, scale);
	
	if (c.useDetail)
	{
		map = SAMPLE_TEXTURE2D(_DetailNormalMap, sampler_DetailNormalMap, c.detailUV);
		scale = INPUT_PROP(_DetailNormalScale) * GetMask(c).b;
		float3 detail = DecodeNormal(map, scale);
		normal = BlendNormalRNM(normal, detail);//将详细法线围绕基本法线旋转
	}
	
	return normal;
}

#endif
