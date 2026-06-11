#ifndef CUSTOM_LIT_PASS_INCLUDED
#define CUSTOM_LIT_PASS_INCLUDED

#include "../ShaderLibiary/Common.hlsl"
#include "../ShaderLibiary/Surface.hlsl"
#include "../ShaderLibiary/Light.hlsl"
#include "../ShaderLibiary/Lighting.hlsl"

TEXTURE2D(_BaseMap);
SAMPLER(sampler_BaseMap);


//对于GPU实例化，想做的事很可能是画100个颜色各不相同的球，而CBuffer里放的float4 _BaseColor就是一个固定的唯一的颜色，一个材质就只有一个颜色，这不合实例化的要求
//改用UNITY_INSTANCING_BUFFER，会让_BaseColor变成一个数组，像是float4 _BaseColor[100]，各实例有自己的颜色，正因此我们需要实例id
UNITY_INSTANCING_BUFFER_START(UnityPerMaterial)
    UNITY_DEFINE_INSTANCED_PROP(float4, _BaseColor)
UNITY_INSTANCING_BUFFER_END(UnityPerMaterial)


struct Attributes {
    float3 positionOS : POSITION;
    float3 normalOS : NORMAL;
    float2 baseUV : TEXCOORD0;
    UNITY_VERTEX_INPUT_INSTANCE_ID//用于GPU实例化的对象索引，for vertex
};

struct Varyings
{
    float4 positionCS : SV_POSITION;
    float3 normalWS : VAR_NORMAL;
    float2 baseUV : VAR_BASE_UV;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

Varyings LitPassVertex(Attributes input)// : SV_Position
{
    Varyings output;
    UNITY_SETUP_INSTANCE_ID(input);//使索引可用
    UNITY_TRANSFER_INSTANCE_ID(input, output);//索引传到frag
    float3 positionWS = TransformObjectToWorld(input.positionOS);
    output.positionCS = TransformWorldToHClip(positionWS);
    output.normalWS = TransformObjectToWorldNormal(input.normalOS);
    output.baseUV = input.baseUV;
    return output;
}

float4 LitPassFragment(Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);//frag里，使索引可用
    
    float4 baseMap = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.baseUV);
    float4 baseColor = UNITY_ACCESS_INSTANCED_PROP(UnityPerMaterial, _BaseColor);
    float4 base = baseMap * baseColor;
    
    Surface surface;
    surface.normal = normalize(input.normalWS);//跨三角形的线性插值会影响法线向量的长度，为了让法线都是单位长度，一定要这么干
    surface.color = base.rgb;
    surface.alpha = base.a;
    
    float3 color = GetLighting(surface);
    return float4(color, surface.alpha);
    return float4(surface.color, surface.alpha);//必须如此，用id获取实例化属性数组里的属性
}

#endif