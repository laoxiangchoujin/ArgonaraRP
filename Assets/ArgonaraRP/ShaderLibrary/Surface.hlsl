#ifndef CUSTOM_SURFACE_INCLUDED
#define CUSTOM_SURFACE_INCLUDED

struct Surface
{
    float3 position;
    float3 normal;
    float3 viewDirection;//视线方向也要作为表面数据传参
    float depth;
    float3 color;
    float alpha;
    float metallic;
    float smoothness;
    float fresnelStrength;
    float dither;//最开始引入是，实现cascade blend的dither混合
};

#endif