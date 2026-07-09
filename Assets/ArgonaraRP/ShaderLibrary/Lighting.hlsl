//Light是声明光的结构，Lighting是光照计算
#ifndef CUSTOM_LIGHTING_INCLUDED
#define CUSTOM_LIGHTING_INCLUDED
//Lighting依赖于Surface，但为了逻辑关系清晰，不在这写，放Lit里面

bool RenderingLayersOverlap (Surface surface, Light light) {
    return (surface.renderingLayerMask & light.renderingLayerMask) != 0;//物体与灯光的渲染层有位重叠，则该光影响此物体
}

float3 IncomingLight(Surface surface,Light light)
{
    return saturate(dot(surface.normal, light.direction) * light.attenuation) * light.color;
}

float3 GetLighting (Surface surface, BRDF brdf, Light light) {//获取直接光lambert
    return IncomingLight(surface, light) * DirectBRDF(surface, brdf, light);
}
float3 GetLighting (Surface surfaceWS, BRDF brdf, GI gi) {
    ShadowData shadowData = GetShadowData(surfaceWS);//利用surface的position算cascade level
    shadowData.shadowMask = gi.shadowMask;
    float3 color = IndirectBRDF(surfaceWS, brdf, gi.diffuse, gi.specular);
    for (int i=0;i<GetDirectionalLightCount();i++)
    {
        Light light = GetDirectionalLight(i, surfaceWS, shadowData);
        if (RenderingLayersOverlap(surfaceWS, light))
        {
            color += GetLighting(surfaceWS, brdf, light);
        }
    }
    #if defined(_LIGHTS_PER_OBJECT)//点光源、聚光灯的逐物体光照
        for (int j = 0; j < min(unity_LightData.y, 8); j++) {//unity_LightData.y是影响本物体的点光/聚光数量，unity设定最大是八个光索引，so单物体最多循环8次
            int lightIndex = unity_LightIndices[(uint)j / 4][(uint)j % 4];//unity_LightIndices，2个float4，压入最多8个灯号，j/4选向量，j%4选分量
            Light light = GetOtherLight(lightIndex, surfaceWS, shadowData);
            if (RenderingLayersOverlap(surfaceWS, light))
            {
                color += GetLighting(surfaceWS, brdf, light);
            }
        }
    #else
        for (int j = 0; j < GetOtherLightCount(); j++) {
            Light light = GetOtherLight(j, surfaceWS, shadowData);
            if (RenderingLayersOverlap(surfaceWS, light))
            {
                color += GetLighting(surfaceWS, brdf, light);
            }
        }
    #endif
    return color;
}

#endif