#ifndef CUSTOM_LIGHTING_INCLUDED
#define CUSTOM_LIGHTING_INCLUDED
//Lighting依赖于Surface，但为了逻辑关系清晰，不在这写，放Lit里面

float3 IncomingLight(Surface surface,Light light)
{
    return saturate(dot(surface.normal, light.direction)) * light.color;
}

float3 GetLighting (Surface surface, Light light) {//获取直接光lambert
    return IncomingLight(surface, light)*surface.color;
}
float3 GetLighting (Surface surface) {
    return GetLighting(surface, GetDirectionalLight());//一个参数的，用直接光，调用两个参数的ver
}

#endif