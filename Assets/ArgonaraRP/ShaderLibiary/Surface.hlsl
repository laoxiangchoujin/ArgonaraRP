#ifndef CUSTOM_SURFACE_INCLUDED
#define CUSTOM_SURFACE_INCLUDED

struct Surface
{
    float3 normal;
    float3 viewDirection;//视线方向也要作为表面数据传参
    float3 color;
    float alpha;
    float metallic;
    float smoothness;
};

#endif