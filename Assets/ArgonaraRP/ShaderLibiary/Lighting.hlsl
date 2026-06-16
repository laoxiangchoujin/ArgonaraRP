//Light是声明光的结构，Lighting是光照计算
#ifndef CUSTOM_LIGHTING_INCLUDED
#define CUSTOM_LIGHTING_INCLUDED
//Lighting依赖于Surface，但为了逻辑关系清晰，不在这写，放Lit里面

float3 IncomingLight(Surface surface,Light light)
{
    return saturate(dot(surface.normal, light.direction) * light.attenuation) * light.color;
}

float3 GetLighting (Surface surface, BRDF brdf, Light light) {//获取直接光lambert
    return IncomingLight(surface, light) * DirectBRDF(surface, brdf, light);
}
float3 GetLighting (Surface surfaceWS, BRDF brdf) {
    ShadowData shadowData = GetShadowData(surfaceWS);//利用surface的position算cascade level
    float3 color = 0.0;
    for (int i=0;i<GetDirectionalLightCount();i++)
    {
        color += GetLighting(surfaceWS, brdf, GetDirectionalLight(i, surfaceWS, shadowData));//一个参数的，用直接光，调用两个参数的ver
    }
    return color;
}

#endif