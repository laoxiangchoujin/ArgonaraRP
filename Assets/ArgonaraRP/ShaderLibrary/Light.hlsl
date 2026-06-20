#ifndef CUSTOM_LIGHT_INCLUDED
#define CUSTOM_LIGHT_INCLUDED

#define MAX_DIRECTIONAL_LIGHT_COUNT 4
#define MAX_OTHER_LIGHT_COUNT 64

CBUFFER_START(_CustomLight)
    int _DirectionalLightCount;
    float4 _DirectionalLightColors[MAX_DIRECTIONAL_LIGHT_COUNT];
    float4 _DirectionalLightDirections[MAX_DIRECTIONAL_LIGHT_COUNT];
    float4 _DirectionalLightShadowData[MAX_DIRECTIONAL_LIGHT_COUNT];//阴影数据，实际上是float2，x是阴影强度，y是atlas上的某个灯的起始tile位置

    //点光源、聚光灯
    int _OtherLightCount;
    float4 _OtherLightColors[MAX_OTHER_LIGHT_COUNT];
    float4 _OtherLightPositions[MAX_OTHER_LIGHT_COUNT];
    float4 _OtherLightDirections[MAX_OTHER_LIGHT_COUNT];//聚光灯需要方向
    float4 _OtherLightSpotAngles[MAX_OTHER_LIGHT_COUNT];
    float4 _OtherLightShadowData[MAX_OTHER_LIGHT_COUNT];
CBUFFER_END

struct Light {//就是平行光
    float3 color;
    float3 direction;
    float attenuation;//对直接光而言，造成衰减的就是阴影
};

int GetDirectionalLightCount()
{
    return _DirectionalLightCount;
}

int GetOtherLightCount () {
    return _OtherLightCount;
}

///获取定向光的阴影数据，有阴影强度和在atlas上的index
DirectionalShadowData GetDirectionalShadowData (int lightIndex, ShadowData shadowData) {
    DirectionalShadowData data;
    data.strength = _DirectionalLightShadowData[lightIndex].x;// * shadowData.strength;//右半的强度，是区分，是否太远超出最大cascade  现在不在这判断了，因为远处要和shadow mask混合，放到shadows.hlsl的MixBakedAndRealtimeShadows里
    data.tileIndex = _DirectionalLightShadowData[lightIndex].y + shadowData.cascadeIndex;//左半是第几个灯，右半是灯的第几个级联
    data.normalBias = _DirectionalLightShadowData[lightIndex].z;
    data.shadowMaskChannel = _DirectionalLightShadowData[lightIndex].w;//本个定向光对应着shadow mask图的哪个通道
    return data;
}

///初始化定向光的所有数据
Light GetDirectionalLight (int index, Surface surfaceWS, ShadowData shadowData)//shadowData负责看在哪个级联
{
    Light light;
    light.color = _DirectionalLightColors[index].rgb;
    light.direction = _DirectionalLightDirections[index].xyz;//光的方向是指向光源的，而非光的去向
    DirectionalShadowData dirShadowData = GetDirectionalShadowData(index, shadowData);
    light.attenuation = GetDirectionalShadowAttenuation(dirShadowData, shadowData, surfaceWS);
    //light.attenuation = shadowData.cascadeIndex * 0.25;//cascade级别的一个可视化，越近越黑，在四个灯的情况下，它按理说最远也就是cascade3，亮度为0.75
    return light;
}

//----------点光源、聚光灯----------//
OtherShadowData GetOtherShadowData (int lightIndex) {
    OtherShadowData data;
    data.strength = _OtherLightShadowData[lightIndex].x;
    data.shadowMaskChannel = _OtherLightShadowData[lightIndex].w;
    return data;
}

Light GetOtherLight (int index, Surface surfaceWS, ShadowData shadowData) {
    Light light;
    light.color = _OtherLightColors[index].rgb;
    float3 ray = _OtherLightPositions[index].xyz - surfaceWS.position;//依旧指向光源
    light.direction = normalize(ray);
    float distanceSqr = max(dot(ray, ray), 0.00001);
    float rangeAttenuation = Square(saturate(1.0 - Square(distanceSqr * _OtherLightPositions[index].w)));//urp在用的Range attenuation curve，光强随距离曲线衰减
    
    //float spotAttenuation =saturate(dot(_OtherLightDirections[index].xyz, light.direction));//聚光灯，保证只有灯正面有光
    float4 spotAngles = _OtherLightSpotAngles[index];
    float spotAttenuation = Square(saturate(dot(_OtherLightDirections[index].xyz, light.direction) * spotAngles.x + spotAngles.y));//点光源的spotAngles值让它不受聚光衰减
    OtherShadowData otherShadowData = GetOtherShadowData(index);
    light.attenuation = GetOtherShadowAttenuation(otherShadowData, shadowData, surfaceWS) * spotAttenuation * rangeAttenuation / distanceSqr;
    return light;
}

#endif