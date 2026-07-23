#ifndef CUSTOM_POST_FX_PASSES_INCLUDED
#define CUSTOM_POST_FX_PASSES_INCLUDED

TEXTURE2D(_PostFXSource);
TEXTURE2D(_PostFXSource2);
//SAMPLER(sampler_linear_clamp);已移至Common.hlsl
float4 _PostFXSource_TexelSize;

struct Varyings
{
    float4 positionCS_SS : SV_POSITION;
    float2 screenUV : VAR_SCREEN_UV;
};

///屏幕后处理，用默认的一个quad两个三角形的方法，比较低效，能量微小
///换成只画一个三角形的左下正方形部分，顶点数6->3，且消除了两个三角形的对角线重复画，有更好的本地缓存一致性，能量巨大
Varyings DefaultPassVertex(uint vertexID : SV_VertexID)
{
    Varyings output;
    output.positionCS_SS = float4(
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


//------------Bloom--------------//


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

float4 BloomAddPassFragment (Varyings input) : SV_TARGET {
    float3 lowRes;
    if (_BloomBicubicUpsampling) {//双三次，采样次数更多，设为可选项    和URP、HDRP的“高质量光晕”(High Quality Bloom)是同一个东西
        lowRes = GetSourceBicubic(input.screenUV).rgb;//只有累加bloom的lowRes，用双三次采样
    }
    else {
        lowRes = GetSource(input.screenUV).rgb;
    }
    float4 highRes = GetSource2(input.screenUV);
    return float4(lowRes * _BloomIntensity + highRes.rgb, highRes.a);//Bloom正确使用模糊前的原纹理的alpha
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
    float3 color = ApplyBloomThreshold(GetSource(input.screenUV).rgb);//只获取大于阈值的颜色
    return float4(color, 1.0);
}

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
//为了避免HDR的少量像素造成的明显闪光，在半分辨率prefilter步骤，先模糊一次    也就是fadeFireFiles    横竖都模糊的
//3*3 blur，结合1/2降分辨率，可以当作是6*6 blur
float4 BloomPrefilterFirefliesPassFragment (Varyings input) : SV_TARGET {
    float3 color = 0.0;
    float weightSum = 0.0;
    float2 offsets[] = {
        float2(0.0, 0.0),
        float2(-1.0, -1.0), float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0),
        //float2(-1.0, 0.0), float2(1.0, 0.0), float2(0.0, -1.0), float2(0.0, 1.0)
    };
    for (int i = 0; i < 5; i++) {//这里从9个sample到5个，没什么影响
        float3 c = GetSource(input.screenUV + offsets[i] * GetSourceTexelSize().xy * 2.0).rgb;
        c = ApplyBloomThreshold(c);
        float w = 1.0 / (Luminance(c) + 1.0);   //要实现，单个像素的luminance亮度越大，它的权重就越小，也能减轻fireFlies
        color += c * w;
        weightSum += w;
    }
    color /= weightSum;
    return float4(color, 1.0);
}

float4 BloomScatterPassFragment (Varyings input) : SV_TARGET {
    float3 lowRes;
    if (_BloomBicubicUpsampling) {//双三次，采样次数更多，设为可选项    和URP、HDRP的“高质量光晕”(High Quality Bloom)是同一个东西
        lowRes = GetSourceBicubic(input.screenUV).rgb;//只有累加bloom的lowRes，用双三次采样
    }
    else {
        lowRes = GetSource(input.screenUV).rgb;
    }
    float3 highRes = GetSource2(input.screenUV).rgb;
    return float4(lerp(highRes, lowRes, _BloomIntensity), 1.0);
}

//散射模式下的最后一个pass，用于补齐暗部亮度，尽可能重建原图的亮度，使之不会因为scatter太强使暗部大量变暗
float4 BloomScatterFinalPassFragment (Varyings input) : SV_TARGET {
    float3 lowRes;
    if (_BloomBicubicUpsampling) {
        lowRes = GetSourceBicubic(input.screenUV).rgb;
    }
    else {
        lowRes = GetSource(input.screenUV).rgb;
    }
    float4 highRes = GetSource2(input.screenUV);
    lowRes += highRes.rgb - ApplyBloomThreshold(highRes.rgb);//+=的部分是，（高分辨率原图-高分原图的高亮部分），也就是暗部
    return float4(lerp(highRes.rgb, lowRes, _BloomIntensity), highRes.a);//Bloom正确使用模糊前的原纹理的alpha
}



//----------------Color Grading-----------------//
//说是，正确的色彩处理顺序是，原始HDR、色彩矫正、色彩分级、色调映射(tonemapping)、显示器LDR
//color correction和color grading合称为color grading色彩分级
float4 _ColorAdjustments;//x是2的expoture次方，y和w是1.0几的对比度和饱和度，z是1/360的色相Hue
float4 _ColorFilter;//是个颜色
float4 _WhiteBalance;
float4 _SplitToningShadows,//这个阴影的xyz存阴影色，w存分离色调的偏移，w更大是对高光的影响更多
    _SplitToningHighlights;
float4 _ChannelMixerRed, _ChannelMixerGreen, _ChannelMixerBlue;
float4 _SMHShadows, _SMHMidtones, _SMHHighlights, _SMHRange;//阴影/中间调/高光染色色 + 过渡范围(start,end,start,end)

float Luminance(float3 color, bool useACES)
{
    return useACES ? AcesLuminance(color) : Luminance(color);
}

float3 ColorGradePostExposure (float3 color) {
    return color * _ColorAdjustments.x;
}

float3 ColorGradingContrast (float3 color, bool useACES) {
    color = useACES ? ACES_to_ACEScc(unity_to_ACES(color)) : LinearToLogC(color);//LogC色彩空间不同于Linear，符合人眼对亮度的感知，对数而非线性，让亮部暗部变化更自然
    color = (color - ACEScc_MIDGRAY) * _ColorAdjustments.y + ACEScc_MIDGRAY;//减去ACEs空间的中灰度ACEScc_MIDGRAY(等于sRGB下的0.4135884)，乘上对比度后再加回去
    return useACES ? ACES_to_ACEScg(ACEScc_to_ACES(color)) : LogCToLinear(color);//调回linear         ACEScg是ACES的线性子集，这一步之后的计算，进入ACES线性或默认线性空间
}

float3 ColorGradeColorFilter (float3 color) {
    return color * _ColorFilter.rgb;//直接相乘，就是，只留下与setting所选的颜色相近的颜色
}

//调整色相
float3 ColorGradingHueShift (float3 color) {
    color = RgbToHsv(color);
    float hue = color.x + _ColorAdjustments.z;//color.x就是H色相，再加上-1~+1的z
    color.x = RotateHue(hue, 0.0, 1.0);//色相是环形的，0和1的值一样     这里<0就+1，>1就-1，这样就不会出现色相跳变
    return HsvToRgb(color);
}

float3 ColorGradingSaturation (float3 color, bool useACES) {
    float luminance = Luminance(color, useACES);
    return (color - luminance) * _ColorAdjustments.w + luminance;//类似对比度
}

float3 ColorGradeWhiteBalance(float3 color)
{
    color = LinearToLMS(color);//LMS色彩空间，将颜色描述为人眼中三种光锥的感应
    color *= _WhiteBalance.rgb;
    return LMSToLinear(color);
}

float3 ColorGradeSplitToning(float3 color, bool useACES)
{
    color = PositivePow(color, 1.0 / 2.2);//转到近似gamma空间，匹配Adobe的split-toning
    float luminance = saturate(Luminance(saturate(color), useACES) + _SplitToningShadows.w);//亮度→插值权重，w存的是balance(-1~1)
    float3 shadows = lerp(0.5, _SplitToningShadows.rgb, 1.0 - luminance);//暗部(t小)去和阴影色混合    亮部与0.5混合，结果不变
    float3 highlights = lerp(0.5, _SplitToningHighlights.rgb, luminance);//亮部(t大)去和高光色混合    暗部与0.5混合，结果不变
    color = SoftLight(color, shadows);//只柔光混合阴影色                             ↑SoftLight(x, 0.5)=原样不变
    color = SoftLight(color, highlights);//只柔光混合高光色
    return PositivePow(color, 2.2);//转回线性空间
}

float3 ColorGradingChannelMixer(float3 color)
{
    return mul(
        float3x3(_ChannelMixerRed.rgb, _ChannelMixerGreen.rgb, _ChannelMixerBlue.rgb),
        color);//矩阵乘法：新RGB = 3×3矩阵 × 原RGB，每行是一个输出通道的权重
}

float3 ColorGradingShadowsMidtonesHighlights(float3 color, bool useACES)
{
    float luminance = Luminance(color, useACES);//每个像素根据亮度分配到三段权重
    float shadowsWeight = 1.0 - smoothstep(_SMHRange.x, _SMHRange.y, luminance);//亮度<start时=1，>end时=0，中间平滑过渡
    float highlightsWeight = smoothstep(_SMHRange.z, _SMHRange.w, luminance);//亮度<start时=0，>end时=1
    float midtonesWeight = 1.0 - shadowsWeight - highlightsWeight;//中间调权重=剩下的部分
    return
        color * _SMHShadows.rgb * shadowsWeight +
        color * _SMHMidtones.rgb * midtonesWeight +
        color * _SMHHighlights.rgb * highlightsWeight;//三段各自×权重×染色色，默认三色全白=无效果
}

float3 ColorGrade(float3 color, bool useACES = false)
{
    //color = min(color,60);//做个安全性控制，防止太大的数出错
    color = ColorGradePostExposure(color);
    color = ColorGradeWhiteBalance(color);//白平衡应用在曝光度后      如果先白平衡再曝光，白平衡就白做了   先全局明暗，再修正亮度
    color = ColorGradingContrast(color, useACES);
    color = ColorGradeColorFilter(color);
    color = max(color, 0.0);//增大对比度可能让画面更暗且出现负值
    color = ColorGradeSplitToning(color, useACES);//分色调，对阴影和高光分别染色
    color = ColorGradingChannelMixer(color);//通道混合器，RGB重映射矩阵
    color = max(color, 0.0);//负权重可能产生负通道值
    color = ColorGradingShadowsMidtonesHighlights(color, useACES);//阴影/中间调/高光三段独立染色
    color = ColorGradingHueShift(color);
    color = ColorGradingSaturation(color, useACES);
    color = max(useACES ? ACEScg_to_ACES(color) : color, 0.0);//调对比度也可能造成负值     若ACES，此时从线性ACES回到非线性ACES
    return color;
}



//----------------ToneMapping-----------------//

//不做色调映射，仅应用颜色分级
float4 _ColorGradingLUTParameters;

//为了让LUT支持HDR，需要把LUT的RGB值转换到LogC色彩空间
//写入LUT的时候，用GetLutStripValue，输入值是lut uv，在0~1，不采样屏幕颜色，那么输出的xyz的三维坐标也是0~1
//应该是，支持0~59的高亮度屏幕颜色输入，所以得让LUT三维坐标覆盖0~59的范围，so，写入LUT时做LogCToLinear让值变大为0~59     使得LUT图的UV是0~1，但像素值是(0~59的值做colorGrading后的任意颜色)
//then，采样时，采样屏幕颜色，是0~59的输入值，做LinearToLogC，让值变小为0~1，符合LUT图的UV范围      使之用屏幕的0~59颜色对应LUT图的0~1UV，正确再采样到(0~59的值做colorGrading后的任意颜色)
bool _ColorGradingLUTInLogC;

//写入LUT查找表
float3 GetColorGradedLUT(float2 uv, bool useACES = false)
{
    float3 color = GetLutStripValue(uv, _ColorGradingLUTParameters);//Core库函数，把二维UV映射到三维RGB，每个UV值，对应一个XYZ三维坐标，对应一个被查找的三维颜色
    return ColorGrade(_ColorGradingLUTInLogC ? LogCToLinear(color) : color, useACES);//toneMapping调用colorGrading     此时，若ACES，已经在ACES色彩空间
}

TEXTURE2D(_ColorGradingLUT);

//采样LUT查找表，用屏幕像素的高亮0~59颜色，去采样LUT，获得LUT上的对应处理后的高亮颜色
float3 ApplyColorGradingLUT(float3 color)
{
    return ApplyLut2D(TEXTURE2D_ARGS(_ColorGradingLUT, sampler_linear_clamp), 
                        saturate(_ColorGradingLUTInLogC ? LinearToLogC(color) : color), 
                        _ColorGradingLUTParameters.xyz);
}

float4 FinalPassFragment(Varyings input) : SV_TARGET
{
    float4 color = GetSource(input.screenUV);
    color.rgb = ApplyColorGradingLUT(color.rgb);
    return color;
}

//当在使用LUT以后，以下几个toneMapping函数并不处理屏幕图像的颜色了
float4 ToneMappingNonePassFragment (Varyings input) : SV_TARGET {
    float3 color = GetColorGradedLUT(input.screenUV);
    return float4(color, 1.0);
}

//学院色彩编码系统，行业标准，需先转换到ACES色彩空间再映射
float4 ToneMappingACESPassFragment (Varyings input) : SV_TARGET {
    float3 color = GetColorGradedLUT(input.screenUV, true);
    color = AcesTonemap(color.rgb);//sRGB/Rec.709 和 ACES 的 RGB 三原色定义不同。unity_to_ACES 是把 Unity 默认的 Rec.709 原色坐标映射到 ACES 的广色域原色坐标，这样 AcesTonemap 才能在正确的色彩空间里计算
    return float4(color, 1.0);
}

//中性色调映射，Uncharted 2风格的S曲线，有趾部+线性段+肩部，能保留更多暗部和亮部细节
//neutral相当于保留了更多亮部亮度的Reinhard
float4 ToneMappingNeutralPassFragment (Varyings input) : SV_TARGET {
    float3 color = GetColorGradedLUT(input.screenUV);
    color = NeutralTonemap(color);
    return float4(color, 1.0);
}

//色调映射：HDR→LDR，Reinhard公式简单压暗超亮区域
//莱因哈特 Reinhard   x = x / (x + 1)
float4 ToneMappingReinhardPassFragment (Varyings input) : SV_TARGET {
    float3 color = GetColorGradedLUT(input.screenUV);
    color /= (color + 1.0);
    return float4(color, 1.0);
}

bool _CopyBicubic;

float4 FinalPassFragmentRescale(Varyings input) : SV_TARGET
{
    if (_CopyBicubic)
    {
        return GetSourceBicubic(input.screenUV);
    }
    else
    {
        return GetSource(input.screenUV);
    }
}



#endif
