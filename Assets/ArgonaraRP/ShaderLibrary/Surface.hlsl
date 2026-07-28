#ifndef CUSTOM_SURFACE_INCLUDED
#define CUSTOM_SURFACE_INCLUDED

struct Surface
{
    float3 position;
    float3 normal;
    float3 interpolatedNormal;//内插法线，它不受法线图影响，用于阴影贴图位移
    float3 viewDirection;//视线方向也要作为表面数据传参
    float depth;
    float3 albedo;
    float alpha;
    float roughness;
    float metallic;
    float occlusion;
    float dither;//最开始引入是，实现cascade blend的dither混合
    uint renderingLayerMask;//渲染层位掩码，控制哪个灯光能照到此表面
};

#endif