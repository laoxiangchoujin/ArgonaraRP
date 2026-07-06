#ifndef CUSTOM_POST_FX_PASSES_INCLUDED
#define CUSTOM_POST_FX_PASSES_INCLUDED

TEXTURE2D(_PostFXSource);
TEXTURE2D(_PostFXSource2);
SAMPLER(sampler_linear_clamp);
float4 _PostFXSource_TexelSize;

struct Varyings
{
    float4 positionCS : SV_POSITION;
    float2 screenUV : VAR_SCREEN_UV;
};

///屏幕后处理，用默认的一个quad两个三角形的方法，比较低效，能量微小
///换成只画一个三角形的左下正方形部分，顶点数6->3，且消除了两个三角形的对角线重复画，有更好的本地缓存一致性，能量巨大
Varyings DefaultPassVertex(uint vertexID : SV_VertexID)
{
    Varyings output;
    output.positionCS = float4(
        vertexID <= 1 ? -1.0 : 3.0,
        vertexID == 1 ? 3.0 : -1.0,//绘制在三角形的左下角，裁剪空间xy是-1~1
        0.0, 1.0
    );
    output.screenUV = float2(
        vertexID <= 1 ? 0.0 : 2.0,
        vertexID == 1 ? 2.0 : 0.0//屏幕空间，uv是0~1
    );
    
    if (_ProjectionParams.x < 0.0) {//如果x<0，则当前图形API导致需要y翻转才正确
        output.screenUV.y = 1.0 - output.screenUV.y;
    }
    
    return output;
}

float4 GetSource(float2 screenUV) {
    return SAMPLE_TEXTURE2D(_PostFXSource, sampler_linear_clamp, screenUV);
}

float4 CopyPassFragment(Varyings input) : SV_Target
{
    return SAMPLE_TEXTURE2D_LOD(_PostFXSource, sampler_linear_clamp, input.screenUV, 0);
}


float4 GetSourceTexelSize () {
    return _PostFXSource_TexelSize;
}

//只是对原图做降采样，会很块状，难看。想做9*9的高斯滤波，但那可能要采样81次太多，
//因为高斯滤波在数学上可分离，9*9的采样等同于在水平1*9+垂直9*1的采样，总采样18次，相对比较可接受，
//再把它和降采样结合，效果等同于18*18的采样，这就是 URP 和 HDRP使用的 Bloom 方法。

float4 BloomHorizontalPassFragment (Varyings input) : SV_TARGET {
    float3 color = 0.0;
    float offsets[] = {
        -4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0
    };
    float weights[] = {
        0.01621622, 0.05405405, 0.12162162, 0.19459459, 0.22702703,
        0.19459459, 0.12162162, 0.05405405, 0.01621622
    };
    for (int i = 0; i < 9; i++) {
        float offset = offsets[i] * 2.0 * GetSourceTexelSize().x;//这个*2，是把图像分辨率除2后，这是为了与之匹配，可以认为是一种双线性滤波
        color += GetSource(input.screenUV + float2(offset, 0.0)).rgb * weights[i];
    }
    return float4(color, 1.0);
}

float4 BloomVerticalPassFragment (Varyings input) : SV_TARGET {
    float3 color = 0.0;
    float offsets[] = {//在高斯采样点之间以适当的偏移量进行采样，从而减少采样量，这只有5个而不是9个了，但不能给Horizontal这样做
        -3.23076923, -1.38461538, 0.0, 1.38461538, 3.23076923
    };
    float weights[] = {
        0.07027027, 0.31621622, 0.22702703, 0.31621622, 0.07027027
    };
    for (int i = 0; i < 5; i++) {
        float offset = offsets[i] * GetSourceTexelSize().y;//对于bloom，每次都是先水平，再竖直，在vertical的时候，分辨率和前一个horizontal的时候一样，offset不用*2
        color += GetSource(input.screenUV + float2(0.0, offset)).rgb * weights[i];
    }
    return float4(color, 1.0);
}

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Filtering.hlsl"

//上采样时用双三次(Bicubic)采样，避免Bilinear的块状光晕（说是运动时会明显）
bool _BloomBicubicUpsampling;
float _BloomIntensity;

float4 GetSourceBicubic(float2 screenUV)
{
    return SampleTexture2DBicubic(TEXTURE2D_ARGS(_PostFXSource, sampler_linear_clamp), screenUV, _PostFXSource_TexelSize.zwxy, 1.0, 0.0);
}

float4 GetSource2(float2 screenUV) {
    return SAMPLE_TEXTURE2D_LOD(_PostFXSource2, sampler_linear_clamp, screenUV, 0);
}

float4 BloomCombinePassFragment (Varyings input) : SV_TARGET {
    float3 lowRes;
    if (_BloomBicubicUpsampling) {//双三次，采样次数更多，设为可选项    和URP、HDRP的“高质量光晕”(High Quality Bloom)是同一个东西
        lowRes = GetSourceBicubic(input.screenUV).rgb;//只有累加bloom的lowRes，用双三次采样
    }
    else {
        lowRes = GetSource(input.screenUV).rgb;
    }
    float3 highRes = GetSource2(input.screenUV).rgb;
    return float4(lowRes * _BloomIntensity + highRes, 1.0);
}

//阈值过滤
float4 _BloomThreshold;

float3 ApplyBloomThreshold (float3 color) {
    float brightness = Max3(color.r, color.g, color.b);
    float soft = brightness + _BloomThreshold.y;
    soft = clamp(soft, 0.0, _BloomThreshold.z);
    soft = soft * soft * _BloomThreshold.w;
    float contribution = max(soft, brightness - _BloomThreshold.x);
    contribution /= max(brightness, 0.00001);
    return color * contribution;
}

float4 BloomPrefilterPassFragment (Varyings input) : SV_TARGET {
    float3 color = ApplyBloomThreshold(GetSource(input.screenUV).rgb);
    return float4(color, 1.0);
}

#endif
