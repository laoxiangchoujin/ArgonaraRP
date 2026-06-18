#ifndef CUSTOM_SHADOWS_INCLUDED
#define CUSTOM_SHADOWS_INCLUDED

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Shadow/ShadowSamplingTent.hlsl"

#if defined(_DIRECTIONAL_PCF3)
    #define DIRECTIONAL_FILTER_SAMPLES 4
    #define DIRECTIONAL_FILTER_SETUP SampleShadow_ComputeSamples_Tent_3x3
#elif defined(_DIRECTIONAL_PCF5)
    #define DIRECTIONAL_FILTER_SAMPLES 9
    #define DIRECTIONAL_FILTER_SETUP SampleShadow_ComputeSamples_Tent_5x5
#elif defined(_DIRECTIONAL_PCF7)
    #define DIRECTIONAL_FILTER_SAMPLES 16
    #define DIRECTIONAL_FILTER_SETUP SampleShadow_ComputeSamples_Tent_7x7
#endif

#define MAX_SHADOWED_DIRECTIONAL_LIGHT_COUNT 4
#define MAX_CASCADE_COUNT 4


TEXTURE2D_SHADOW(_DirectionalShadowAtlas);//TEXTURE2D_SHADOW实际上就是TEXTURE2D，就这样写罢
#define SHADOW_SAMPLER sampler_linear_clamp_compare
SAMPLER_CMP(SHADOW_SAMPLER);//SAMPLER_CMP被定义为SamplerComparisonState，因为常规的双线性过滤对于深度数据没有意义

CBUFFER_START(_CustomShadows)
    int _CascadeCount;
    float4 _CascadeCullingSpheres[MAX_CASCADE_COUNT];//xyz是球心（实际在相机往前一小段距离），w是半径
    float4 _CascadeData[MAX_CASCADE_COUNT];
    float4x4 _DirectionalShadowMatrices[MAX_SHADOWED_DIRECTIONAL_LIGHT_COUNT * MAX_CASCADE_COUNT];
    //float _ShadowDistance;//最大阴影距离
    float4 _ShadowAtlasSize;//图集的大小和纹素大小
    float4 _ShadowDistanceFade;//x是1/最大距离，y是1/距离衰减，z是cascadeFade的一个带平方的因子
CBUFFER_END

//per-light的阴影数据    "这个光源的阴影有多强、它在 atlas 的哪个位置、法线偏移多少"
//在 Light.hlsl 的 GetDirectionalShadowData 里从 _DirectionalLightShadowData[lightIndex] 读取，再往上又是Lighting.cs调用Shadows.cs的ReserveDirectionalShadows写入数组的
struct DirectionalShadowData
{
    float strength;
    int tileIndex;//这个光源在哪个tile上
    float normalBias;
    int shadowMaskChannel;//支持多光源，不要硬编码采baked shadow的r通道
};

float SampleDirectionalShadowAtlas (float3 positionSTS) {//这个STS大概是shadow tex space的意思
    return SAMPLE_TEXTURE2D_SHADOW(_DirectionalShadowAtlas, SHADOW_SAMPLER, positionSTS);//这个函数SAMPLE_TEXTURE2D_SHADOW自动做了Z深度比较，不用我手动
    //甚至codebuddy说配合 SamplerComparisonState（sampler_linear_clamp_compare），还会在周围像素做 PCF 软阴影，linear在相邻4个texel做双线性插值
    //SAMPLE_TEXTURE2D_SHADOW 返回的 不是深度值，而是比较结果：0 = 完全阴影，1 = 完全照亮，中间值 = 半影。
}

//是否用了Shadow Mask模式来烘焙阴影的一些信息
struct ShadowMask
{
    bool always;
    bool distance;//是否是，“DISTANCE”的类型
    float4 shadows;
};

//per-fragment 的阴影数据    "这个片元该用第几个级联、要不要和下一级联混合、阴影强度衰减到多少"
//在 GetShadowData 里计算, 然后传给 GetDirectionalShadowAttenuation 去实际采样
struct ShadowData
{
    int cascadeIndex;
    float cascadeBlend;//让阴影在级联之间平滑过渡，是个淡出因子
    float strength;//可能是用于，太远处的超出最后一个级联，把它强度设为0
    ShadowMask shadowMask;
};

float FilterDirectionalShadow(float3 positionSTS)
{
    #if defined(DIRECTIONAL_FILTER_SETUP)//当定义了DIRECTIONAL_FILTER_SETUP，会执行多次采样
    float weights[DIRECTIONAL_FILTER_SAMPLES];
    float2 positions[DIRECTIONAL_FILTER_SAMPLES];
    float4 size = _ShadowAtlasSize.yyxx;//yyxx，里面，y是纹素大小，x是图集大小//？为什么要知道图集大小？
    DIRECTIONAL_FILTER_SETUP(size, positionSTS.xy, weights, positions);
    float shadow = 0;
    for (int i = 0; i < DIRECTIONAL_FILTER_SAMPLES; i++) {
        shadow += weights[i] * SampleDirectionalShadowAtlas(
            float3(positions[i].xy, positionSTS.z)
        );
    }
    return shadow;
    #else
    return SampleDirectionalShadowAtlas(positionSTS);//只采样一次
    #endif
}

float GetCascadedShadow(DirectionalShadowData directional, ShadowData global, Surface surfaceWS)
{
    // tileIndex = 光源在atlas的起始偏移(cascadeCount * lightIndex) + 当前级联索引(cascadeIndex)
    // CPU端ReserveDirectionalShadows的.y是每个灯的起始偏移，存入Light.hlsl的_DirectionalLightShadowData[lightIndex].y，，，
    //      RenderDirectionalShadows按tileIndex索引写入dirShadowMatrices[tileIndex]
    // GPU端Light.hlsl里GetDirectionalShadowData从_DirectionalLightShadowData[lightIndex].y + cascadeIndex 还原tileIndex，用它取对应矩阵，保证矩阵数组索引一一对应
    float3 normalBias = surfaceWS.normal * (directional.normalBias * _CascadeData[global.cascadeIndex].y);;//这个y是，shadow map的tile纹素在世界空间中对应的长度，在阴影采样时，在法线方向上偏移这么多，避免阴影边缘的锯齿
    float3 positionSTS = mul(_DirectionalShadowMatrices[directional.tileIndex],float4(surfaceWS.position +normalBias, 1.0)).xyz;
    float shadow = FilterDirectionalShadow(positionSTS);//正带上pcf滤波，去采样
    
    if (global.cascadeBlend < 1.0)//在两个级联的交界混合区域
    {
        normalBias = surfaceWS.normal * (directional.normalBias * _CascadeData[global.cascadeIndex + 1].y);
        positionSTS = mul(_DirectionalShadowMatrices[directional.tileIndex + 1],float4(surfaceWS.position +normalBias, 1.0)).xyz;
        shadow = lerp(FilterDirectionalShadow(positionSTS), shadow, global.cascadeBlend);
    }
    return shadow;
}

float GetBakedShadow(ShadowMask mask, int channel)
{
    float shadow = 1.0;
    if (mask.always || mask.distance)
    {
        if (channel >= 0) {
            shadow = mask.shadows[channel];
        }
    }
    return shadow;
}

///用于支持，存在shadow mask同时没有实时阴影的情况
float GetBakedShadow (ShadowMask mask, int channel, float strength) {
    if (mask.always || mask.distance) {
        return lerp(1.0, GetBakedShadow(mask, channel), strength);
    }
    return 1.0;
}

float MixBakedAndRealtimeShadows(ShadowData global, float shadow, int shadowMaskChannel, float strength)//这里的第二个shadow变量，就是实时阴影，也就是级联阴影
{
    float baked = GetBakedShadow(global.shadowMask, shadowMaskChannel);
    if (global.shadowMask.always) {//shadow mask模式为shadow mask，不执行静态物体的shadow caster pass，省的消耗就是这个，仍会采样shadow map，但采样的时候对应位置没内容，和baked阴影取min，就是采用baked阴影
        shadow = lerp(1.0, shadow, global.strength);
        shadow = min(baked, shadow);
        return lerp(1.0, shadow, strength);
    }
    if (global.shadowMask.distance)//若用了Distance Shadow Mask模式烘焙阴影，会有enableKeyword导致这个distance变为true的
    {
        shadow = lerp(baked, shadow, global.strength);
        return lerp(1.0, shadow, strength);
    }
    return lerp(1.0, shadow, strength * global.strength);//这个global.strength就是实时阴影最大距离的衰减，这里没在用baked，就直接在外围衰减到0，上边，用这个值，和baked shadow混合
}

//获取直接光的经过阴影处理的剩余光照强度
float GetDirectionalShadowAttenuation (DirectionalShadowData directional, ShadowData global, Surface surfaceWS) {
    #if !defined(_RECEIVE_SHADOWS)
        return 1.0;
    #endif
    
    float shadow;
    // if (directional.strength <= 0.0) {//旧写法，directional.strength是定向光的阴影强度，当相机离太远，物体超出最大级联距离 → GetShadowCasterBounds 返回 false → ReserveDirectionalShadows 返回 Vector3.zero → directional.strength = 0，就完全没有任何阴影
    //     shadow = 1.0;
    // }
    if (directional.strength * global.strength <= 0.0)//新写法，物体离相机太远超出最大级联距离，或，像素接近最外层级联外边缘强度降到0，这个实际上是“实时阴影完全不可用”的情况，就采样烘焙的shadow
    {
        shadow = GetBakedShadow(global.shadowMask, directional.shadowMaskChannel, abs(directional.strength));//这里的abs，是cullingResults.GetShadowCasterBounds为false的情况
    }
    else//物体与相机距离在最大级联距离之内，并且，如果在最外层衰减强度还没衰减到0，就混合采样实时和烘焙阴影     有阴影且没衰减，就是实时阴影；有阴影有衰减，就是实时与烘焙和混合
    {
        shadow = GetCascadedShadow(directional, global, surfaceWS);
        //shadow = lerp(1.0, shadow, directional.strength);//经过阴影，和阴影强度处理后的剩余光照强度
        shadow = MixBakedAndRealtimeShadows(global, shadow, directional.shadowMaskChannel, directional.strength);
    }
    //上边的if else，实际上更适合让else的情况作为if出现，因为只是看上边的if，是不觉得有什么合理的逻辑的
    
    return shadow;
}

float FadedShadowStrength(float distance, float scale, float fade)
{
    return saturate((1.0 - distance * scale) * fade);//本来是除的，但setGloablVector的时候已经除完了
}

///级联索引是根据片段而不是光源确定的
///用于返回WS的surface的阴影数据
ShadowData GetShadowData (Surface surfaceWS)
{
    ShadowData data;
    data.shadowMask.always = false;
    data.shadowMask.distance = false;//给个默认值，等到GetLighting里，由GI传给它
    data.shadowMask.shadows = 1.0;
    data.cascadeBlend = 1.0;
    //data.strength = 1;//只依赖cascadeSphere的强度剔除（就是没剔除），在最大级联和更远的地方的交界，会出现逐物体而不是逐片元的有无阴影的突变
    //      假设一个投射物X距离相机 12.5m，_maxDistance = 12，最外层裁切球半径 ≈ 14，裁切球判断：12.5 < 14 → X 在最外层球内 → cascadeIndex=3 → 正常采样，而12.5 > 12，context.drawShadows会参考 _maxDistance做逐物体剔除，投射物x可能被剔除掉
    //data.strength = surfaceWS.depth < _ShadowDistance ? 1.0 : 0.0;//↑，因此加上最大距离剔除    //此时，depth是视空间深度，在屏幕上看来，是一个沿屏幕向里的矩形，而不是某种圆形
    data.strength = FadedShadowStrength(surfaceWS.depth, _ShadowDistanceFade.x, _ShadowDistanceFade.y);//做了远处的阴影强度逐渐衰减到0，顺便也满足了上边的距离裁切
    int i;
    for (i = 0; i < _CascadeCount; i++)
    {
        float4 sphere = _CascadeCullingSpheres[i];
        float distanceSqr = DistanceSquared(surfaceWS.position, sphere.xyz);
        if (distanceSqr < sphere.w)//如果某个片元在更小的cascade球里面，就采用此级联
        {
            float fade = FadedShadowStrength(distanceSqr, _CascadeData[i].x, _ShadowDistanceFade.z);//对每一个级联都算一次fade
            if (i == _CascadeCount - 1)//若到最大级联，则强度衰减
            {
                data.strength *= fade;
            }
            else
            {
                data.cascadeBlend = fade;//算的原理和最外层级联渐变到0一样，只不过这是更小的球。混合值<1，说明在过渡区域，要在下一个级联中采样，插值混合
            }
            break;
        }
    }
    if (i == _CascadeCount)
    {
        data.strength = 0.0;//太远的地方，超出最后一个级联，强度设为0，直接避免采样
    }
    #if defined(_CASCADE_BLEND_DITHER)
        else if (data.cascadeBlend < surfaceWS.dither)
        {
            i += 1;
        }
    #endif
    #if !defined(_CASCADE_BLEND_SOFT)
        data.cascadeBlend = 1.0;//如果不使用软混合，则强制为1，避免为此采样两次
    #endif
    data.cascadeIndex = i;
    return data;
}



#endif