#ifndef CUSTOM_META_PASS_INCLUDED
#define CUSTOM_META_PASS_INCLUDED

#include "../ShaderLibrary/Surface.hlsl"
#include "../ShaderLibrary/Shadows.hlsl"
#include "../ShaderLibrary/Light.hlsl"
#include "../ShaderLibrary/BRDF.hlsl"

bool4 unity_MetaFragmentControl;
float unity_OneOverOutputBoost;
float unity_MaxOutputValue;

struct Attributes {
	float3 positionOS : POSITION;
	float2 baseUV : TEXCOORD0;
	float2 lightMapUV : TEXCOORD1;//就像在采样光照贴图时一样，我们需要光照贴图的 UV 坐标
};

struct Varyings {
	float4 positionCS : SV_POSITION;
	float2 baseUV : VAR_BASE_UV;
};

Varyings MetaPassVertex (Attributes input) {
	Varyings output;
	//lightMapUV 在这不是用来采样 Lightmap，而是把物体从 3D 空间"展开"成 2D 的 Lightmap 布局，让 GPU 在这张展开图上重画一遍物体材质。
	input.positionOS.xy = input.lightMapUV * unity_LightmapST.xy + unity_LightmapST.zw;//物体在lightmap上的xy坐标，也就是lightmapUV，作为ObjectSpace的xy
	input.positionOS.z = input.positionOS.z > 0.0 ? FLT_MIN : 0.0;//纯粹为了兼容 OpenGL，OpenGL 要求 Z 坐标有明确的值，否则可能编译报错，烘焙器不关心深度
	output.positionCS = TransformWorldToHClip(input.positionOS);//该函数执行的是与其名称所暗示的不同类型的转换
	output.baseUV = TransformBaseUV(input.baseUV);
	return output;
}

float4 MetaPassFragment (Varyings input) : SV_TARGET {
	float4 base = GetBase(input.baseUV);
	Surface surface;
	ZERO_INITIALIZE(Surface, surface);
	surface.color = base.rgb;
	surface.metallic = GetMetallic(input.baseUV);
	surface.smoothness = GetSmoothness(input.baseUV);
	BRDF brdf = GetBRDF(surface);
	float4 meta = 0.0;
	
	if (unity_MetaFragmentControl.x)//若有x，则请求漫反射
	{
		meta = float4(brdf.diffuse, 1.0);
		meta.rgb += brdf.specular * brdf.roughness * 0.5;//添加0.5*经过粗糙度缩放的specular来提升结果。背后的理念是高度镜面反射但粗糙的材质也会传递一些间接光//不用smoothness是因为，是间接光
		meta.rgb += min(PositivePow(meta.rgb, unity_OneOverOutputBoost), unity_MaxOutputValue);
	}
	else if (unity_MetaFragmentControl.y) {//自发光光照是通过单独的通道进行烘焙的，材质面板的“全局光照”设为baked的，会另外执行一次自发光的烘焙
		meta = float4(GetEmission(input.baseUV), 1.0);
	}
	return meta;
}

#endif