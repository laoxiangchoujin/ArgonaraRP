#ifndef CUSTOM_SHADOWS_INCLUDED
#define CUSTOM_SHADOWS_INCLUDED

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Shadow/ShadowSamplingTent.hlsl"

//定向光与其他光源共用同一套滤波档位：合并成一组关键字，
//变体数由 方向光5 × 其他光4 = 20 降到 4（_DIRECTIONAL_PCSS 已单独拆成一条 multi_compile）
#if defined(_SHADOW_PCF3)
    #define SHADOW_FILTER_SAMPLES 4
    #define SHADOW_FILTER_SETUP SampleShadow_ComputeSamples_Tent_3x3
#elif defined(_SHADOW_PCF5)
    #define SHADOW_FILTER_SAMPLES 9
    #define SHADOW_FILTER_SETUP SampleShadow_ComputeSamples_Tent_5x5
#elif defined(_SHADOW_PCF7)
    #define SHADOW_FILTER_SAMPLES 16
    #define SHADOW_FILTER_SETUP SampleShadow_ComputeSamples_Tent_7x7
#endif

#define MAX_SHADOWED_DIRECTIONAL_LIGHT_COUNT 4
#define MAX_CASCADE_COUNT 8

#define MAX_SHADOWED_OTHER_LIGHT_COUNT 16

TEXTURE2D_SHADOW(_DirectionalShadowAtlas);//TEXTURE2D_SHADOW实际上就是TEXTURE2D，就这样写罢
TEXTURE2D_SHADOW(_OtherShadowAtlas);
#define SHADOW_SAMPLER sampler_linear_clamp_compare
SAMPLER_CMP(SHADOW_SAMPLER);//SAMPLER_CMP被定义为SamplerComparisonState，因为常规的双线性过滤对于深度数据没有意义

//屏幕空间阴影图（第3步）：延迟渲染时由 CameraRendererDeferred 生成并绑定；
//非延迟路径（前向）没有这张图，用 _ScreenSpaceShadowEnabled 关掉，不会去采样它
TEXTURE2D(_ScreenSpaceShadowTex);

CBUFFER_START(_CustomShadows)
    int _CascadeCount;
    float4 _CascadeCullingSpheres[MAX_CASCADE_COUNT];//xyz是球心（实际在相机往前一小段距离），w是半径
    float4 _CascadeData[MAX_CASCADE_COUNT];
    float4x4 _DirectionalShadowMatrices[MAX_SHADOWED_DIRECTIONAL_LIGHT_COUNT * MAX_CASCADE_COUNT];
    float4x4 _OtherShadowMatrices[MAX_SHADOWED_OTHER_LIGHT_COUNT];
    float4 _OtherShadowTiles[MAX_SHADOWED_OTHER_LIGHT_COUNT];//目前只有w存了透视灯光的距离1位置的shadow normal bias
    //float _ShadowDistance;//最大阴影距离
    float4 _ShadowAtlasSize;//定向光的图集大小：x=像素宽, y=1/宽, z=像素高, w=1/高（图集可能是长方形）
    float4 _OtherShadowAtlasSize;//其他光源的图集大小：x=正方形边长, y=1/边长（与定向光解耦，各传各的）
    float4 _ShadowDistanceFade;//x是1/最大距离，y是1/距离衰减，z是cascadeFade的一个带平方的因子
    //级联混合模式：0=Hard 1=Soft 2=Dither。
    //原来这 3 种是编译变体(_CASCADE_BLEND_SOFT/_CASCADE_BLEND_DITHER)，现在改成运行时 uniform：
    //它是管线资产里的全局设置（全屏所有像素同一条路），分支开销可忽略，但变体少 3 倍、且切换它不再触发重新编译。
    int _CascadeBlendMode;
    //这一趟是否直接采样屏幕空间阴影图（0=否，1=是）。由延迟渲染器在光照Pass前设1、之后设0；
    //前向渲染不设置它，所以永远是0（前向也没有GBuffer，生不出这张图）
    float _ScreenSpaceShadowEnabled;
    //PCSS（shader里只对主定向光生效）
    float _DirectionalPCSSSearchRadius;//Blocker Search 世界半径锚点(= 最细级联的N个纹素)，shader里再保证每个级联≥1个自己的纹素
    float _DirectionalPCSSPenumbraRef;//深度差归一化的参考长度(世界，= 最细级联球半径)
    float _DirectionalPCSSPenumbraMaxWorld;//半影上限(世界长度，= 最细级联的N个纹素；与级联无关)
    int _DirectionalPCSSBlockerSamples;
    int _DirectionalPCSSSamples;
    float _DirectionalPCSSPenumbraPow;
    float _DirectionalPCSSPadding;//基础深度偏移(占光相机深度范围的比例)
    float _DirectionalPCSSSlopeBias;//深度偏移随斜率(掠射角)与核半径的强度
    float _DirectionalPCSSNormalBias;//沿几何法线偏移着色点(单位:阴影纹素世界尺寸的倍数)
    float3 _DirectionalPCSSLightDir;//主光方向(指向光源)
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
    bool always;//是否是，“shadow mask”的类型
    bool distance;//是否是，“DISTANCE shadow mask”的类型
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
    #if defined(SHADOW_FILTER_SETUP)//当定义了SHADOW_FILTER_SETUP，会执行多次采样
    float weights[SHADOW_FILTER_SAMPLES];
    float2 positions[SHADOW_FILTER_SAMPLES];
    //定向光图集可能是长方形：存的是x=像素宽,y=1/宽,z=像素高,w=1/高
    //而tent filter要的size是：.xy=纹素尺寸(1/宽,1/高)，.zw=像素尺寸(宽,高)
    float4 size = float4(_ShadowAtlasSize.y, _ShadowAtlasSize.w, _ShadowAtlasSize.x, _ShadowAtlasSize.z);
    SHADOW_FILTER_SETUP(size, positionSTS.xy, weights, positions);
    float shadow = 0;
    for (int i = 0; i < SHADOW_FILTER_SAMPLES; i++) {
        shadow += weights[i] * SampleDirectionalShadowAtlas(
            float3(positions[i].xy, positionSTS.z)
        );
    }
    return shadow;
    #else
    return SampleDirectionalShadowAtlas(positionSTS);//只采样一次
    #endif
}

//=========================================================
//====== PCSS（仅主定向光；世界单位半径 → tile内uv半径）======
//=========================================================
#define PCSS_MAX_SAMPLES 32

//半影mask的判据阈值（单位：mask纹素个数）：本地半影要粗过它，才值得交给PCSS。
//0.5 = 半影至少要 2 个屏幕像素粗（mask纹素 = 4 个屏幕像素）。
//放在这里而不是 ScreenSpacePCSS.shader 里：Shadows.hlsl 是共享库（Terrain 等材质也会 include 它），
//而 shader 的 HLSLINCLUDE 里"include 在 define 之前"，定在那边这个文件根本看不到。
#ifndef MASK_BAND_MIN_TEXELS
    #define MASK_BAND_MIN_TEXELS 0.5
#endif

//固定32点泊松盘：前16点为AKG文章表，后16点为其0.5倍内圈。Blocker Search 与 PCF 共用。
static const float2 pcssDisk[PCSS_MAX_SAMPLES] = {
float2(0.04369664,-0.17067612),float2(0.94583898,0.92166932),
float2(-0.95956321,0.66523969),float2(0.97674768,-0.79591038),
float2(-0.85792788,-0.82574140),float2(-0.12482558,0.78354600),
float2(0.95352218,0.20969104),float2(-0.88394168,-0.13116675),
float2(0.04649611,-0.81211898),float2(0.33353343,0.34127574),
float2(0.62759564,-0.20698852),float2(0.42848260,0.99769401),
float2(-0.39984576,-0.42244461),float2(-0.15269040,0.29178823),
float2(-0.39955182,-0.95871164),float2(-0.76345115,0.27984204),
float2(0.30621665,-0.49341679),float2(-0.47088878,0.54846738),
float2(0.39526239,-0.87954906),float2(-0.40688747,0.98402249),
float2(0.95723668,0.59831713),float2(-0.06737845,-0.51114882),
float2(-0.71329343,0.88933783),float2(-0.28098420,-0.12593609),
float2(-0.70520720,-0.51510397),float2(0.92732552,-0.23311696),
float2(0.33652984,-0.12550643),float2(-0.50249371,0.15231467),
float2(0.55631350,0.74002430),float2(0.58739541,-0.55215062),
float2(-0.96161360,-0.39685037),float2(0.90190522,-0.53315949)
};

//归一化深度 → 距光相机近平面的相对距离（乘深度范围才是世界距离；PCSS只求比值，该因子会约掉）
float PCSSDepthToNear (float d)
{
    #if UNITY_REVERSED_Z
        return 1.0 - d;
    #else
        return d;
    #endif
}

//该级联tile里一个纹素对应的世界尺寸（PCSS各bias的单位之一）
float PCSSWorldTexelSize (int cascadeIndex)
{
    int cascadeCount = max(_CascadeCount, 1);
    float tileSizePx = max(_ShadowAtlasSize.x, 1.0) / cascadeCount;//atlas每级联一列，tile等宽
    return max(_CascadeData[cascadeIndex].z, 1e-4) / tileSizePx;
}

//PCSS 的 bias 用一个稳定的几何法线：直接用 Surface 里的内插法线（不受法线图影响），
//并翻正到朝向光源一侧。旧的屏幕导数法线在画面边缘会算歪 → 斜率爆炸 → 阴影整块消失。
float3 PCSSBiasNormal (Surface surfaceWS)
{
    float3 n = surfaceWS.interpolatedNormal;
    n *= (dot(n, _DirectionalPCSSLightDir) < 0.0 ? -1.0 : 1.0);
    return n;
}

//PCSS自己的“沿法线偏移着色点”，与PCF路径解耦：调PCF滤波不会带动它。
//口径与PCF对齐：PCF的偏移是 shadowNormalBias * filterSize * 1.414，而 filterSize 在 PCF2x2(最细档) 时 = 1纹素，
//所以这里同样取 1.414 纹素 → 把 pcssNormalBias 填成主光的 Shadow Normal Bias，开关PCSS时阴影边界就不会移动。
//(原来还乘了 (1-nl)：地面+45°光只剩 0.18 纹素，比 PCF 小约 8 倍 → 阴影远侧边缘外扩，看起来像"阴影整体平移")
float3 PCSSNormalBiasOffset (int cascadeIndex, float3 nWS)
{
    return nWS * (PCSSWorldTexelSize(cascadeIndex) * _DirectionalPCSSNormalBias * 1.4142136);
}

//统一到世界距离比较：采样点比着色点更靠近光源、且超出bias余量 → 判定为遮挡/阴影
bool PCSSShadowed (float sampleZ, float receiverDist, float biasWS, float depthRange)
{
    return PCSSDepthToNear(sampleZ) * depthRange + biasWS < receiverDist;
}

//阴影图是深度纹理，读原始深度只能用 point 采样（对比采样器读不到深度值）
float SamplePCSSDepth (float2 uv)
{
    return SAMPLE_TEXTURE2D(_DirectionalShadowAtlas, sampler_point_clamp, uv).r;
}

//旋转泊松盘样本
float2 RotatePCSSSample (float2 dir, float2 sinCos)
{
    return float2(sinCos.y * dir.x - sinCos.x * dir.y,
                  sinCos.x * dir.x + sinCos.y * dir.y);
}

//把本tile的 uv 核半径夹进可用范围，**整体等比**缩放（形状必须保持不变，否则圆会被压成椭圆）：
//① 每轴至少1纹素：半径过小会退化成单样本硬边；
//② 不超过"到本tile边界的距离"：越界样本被逐个clamp回边界会挤成一列纹素、读到别处深度。
//半径进入这里之前已经分轴换算过（见 worldToUV2），所以等比缩放后在世界空间里仍是正圆。
float2 PCSSFitKernelUV (float2 radiusUV, float2 roomToTile, float2 texelUV)
{
    radiusUV = max(radiusUV, 1e-6);
    //每轴至少1纹素：取两轴里需要放大的较大倍率，等比放大
    float grow = max(texelUV.x / radiusUV.x, texelUV.y / radiusUV.y);
    radiusUV *= max(1.0, grow);
    //不超过本tile剩余空间：取两轴里最紧的那个倍率，等比缩小
    float2 fit = roomToTile / max(radiusUV, 1e-6);
    return radiusUV * min(1.0, min(fit.x, fit.y));
}

//主定向光的 PCSS：Blocker Search → 半影半径(世界单位) → 变半径 PCF
//slope = tanθ(由几何法线与光方向得出)，用于随掠射角变化的深度偏移
float PCSSDirectionalShadow (float3 positionSTS, int tileIndex, float2 sinCos, float slope)
{
    int cascadeCount = max(_CascadeCount, 1);
    int cascadeIndex = tileIndex % cascadeCount;//tileIndex = 灯起始偏移(灯序号×级联数) + 级联索引

    //atlas：每灯一行、每级联一列，tile是正方形像素块。算出本tile的uv范围并夹住采样，避免大半径读到隔壁tile
    float uvWidth = 1.0 / cascadeCount;
    float uvHeight = max(_ShadowAtlasSize.x, 1.0) * uvWidth / max(_ShadowAtlasSize.z, 1.0);
    float2 uvSize = float2(uvWidth, uvHeight);
    float2 uvMin = float2(tileIndex % cascadeCount, tileIndex / cascadeCount) * uvSize;
    float2 halfTexel = _ShadowAtlasSize.yw * 0.5;
    float2 uvClampMin = uvMin + halfTexel;
    float2 uvClampMax = uvMin + uvSize - halfTexel;
    //采样核必须装得进本tile：否则把越界样本逐个clamp回边界，会让它们挤成一列纹素、读到别处深度
    float2 roomToTile = min(positionSTS.xy - uvClampMin, uvClampMax - positionSTS.xy);
    float2 texelUV = _ShadowAtlasSize.yw;//每轴1个纹素对应的uv长度（图集是长方形，两轴uv长度不同）

    float orthoWidth = max(_CascadeData[cascadeIndex].z, 1e-4);//该级联tile覆盖的正交世界宽度
    float depthRange = max(_CascadeData[cascadeIndex].w, 1e-4);//光相机深度范围(far-near)，深度→世界距离用
    //世界长度 → atlas uv 长度：**必须分轴**。tile在像素上是正方形(正交框也是正方形)，但同一个世界半径
    //换算到uv时两轴长度不同：x轴 1世界单位 = uvWidth/orthoWidth，y轴 = uvHeight/orthoWidth
    //(1灯8级联时 uvHeight 是 uvWidth 的8倍)。用标量的话核在光空间里会被拉成8:1的椭圆 → 模糊变成有方向的。
    float2 worldToUV2 = float2(uvWidth, uvHeight) / orthoWidth;
    float texelWorld = orthoWidth / max(_ShadowAtlasSize.x * uvWidth, 1e-4);//1纹素的世界尺寸（tile在像素上是正方形，两轴相同）

    float receiverDist = PCSSDepthToNear(positionSTS.z) * depthRange;//世界距离
    //固定深度偏移：padding 定义为深度范围的比例，所以乘 depthRange
    float baseBiasWS = _DirectionalPCSSPadding * depthRange;

    //① Blocker Search：只在“确实遮挡”的样本上统计平均遮挡深度
    int blockerSamples = clamp(_DirectionalPCSSBlockerSamples, 4, PCSS_MAX_SAMPLES);
    //搜索半径(世界)：C# 上传的是“最细级联的 N 个纹素”那么大，这里再保证每个级联至少能搜到自己 1 个纹素
    //(否则最粗的几个级联连 1 个纹素都搜不到 → 永远找不到 blocker → 那些级联变成硬阴影)
    //下限取1而不是2：它正比于级联尺寸，取2会让粗级联搜的世界范围反超锚点(粗级联反而更糊)
    float searchWorld = max(_DirectionalPCSSSearchRadius, texelWorld);
    float2 searchUV = PCSSFitKernelUV(searchWorld * worldToUV2, roomToTile, texelUV);//分轴换算 + 整体等比缩放
    //blocker search 的容差要覆盖“搜索半径内接收面自身的深度起伏”，也就是正好等于"核跨过的地形起伏"。
    //这里不加 clamp：加了会让平面自身的邻居被误判成遮挡物(假 blocker)，而且细级联被截得最厉害。
    float biasBlockerWS = baseBiasWS + (texelWorld + searchWorld) * slope * _DirectionalPCSSSlopeBias;
    float blockerSum = 0.0;//世界距离
    int blockerCount = 0;
    for (int i = 0; i < blockerSamples; i++)
    {
        float2 offset = RotatePCSSSample(pcssDisk[i], sinCos) * searchUV;
        float2 uv = clamp(positionSTS.xy + offset, uvClampMin, uvClampMax);
        float sampleZ = SamplePCSSDepth(uv);
        if (PCSSShadowed(sampleZ, receiverDist, biasBlockerWS, depthRange))
        {
            blockerSum += PCSSDepthToNear(sampleZ) * depthRange;
            blockerCount++;
        }
    }

    //② 半影：深度差用"与级联无关的世界参考长度"归一化，半影上限本身也是世界长度 → 各级联视觉一致
    float2 radiusUV = 0.0;
    float penumbraWS = 0.0;
    if (blockerCount > 0)
    {
        float blockerDist = blockerSum / blockerCount;
        //深度差是纯世界量(与级联无关)，除以一个固定的世界参考长度 → 同一块几何在各级联得到同一个比值。
        //(旧的 (d_r-d_b)/d_b 里 d_b 含着"光相机到影机的距离"，它正比于级联半径 →
        // 同一个深度差，细级联算出的比值比粗级联大几十~几百倍 → 这就是"内侧特别糊"的根因)
        float ratio = saturate((receiverDist - blockerDist) / max(_DirectionalPCSSPenumbraRef, 1e-5));
        //按命中遮挡物的比例淡入，避免亮侧边缘硬切/闪烁
        float hitFade = saturate((float)blockerCount / max(1.0, (float)blockerSamples * 0.5));
        //半影上限是世界长度(与级联无关)；级联相关的量只出现在下面这一步“世界→uv”的换算里
        penumbraWS = ratio * _DirectionalPCSSPenumbraMaxWorld * hitFade;//给下面 bias 用的世界核半径
        radiusUV = pow(penumbraWS * worldToUV2, _DirectionalPCSSPenumbraPow);
    }
    //下限抬到"PCF 档位本身的核半径"：PCF 是下限、PCSS 在它之上再加半影 → PCSS 永远不会比 PCF 更硬。
    //(不加这个下限时：世界半影在粗级联里往往不足1个纹素 → 半径归零；而 PCSS 的深度是 point 采样，
    // 没有 PCF 那种硬件双线性比较带来的亚纹素过渡 → 它会退化成比 PCF2x2 还硬的二值边。
    // 遮挡物没搜到时同样走这条下限，于是那种情况退化成"和 PCF 一样"，而不是硬边)
    //PCF 核的世界半径 = filterSize = _CascadeData.y / 1.414（y 里存的是 filterSize*1.414）
    float pcfKernelWS = _CascadeData[cascadeIndex].y * 0.70710678;
    if (penumbraWS < pcfKernelWS)
    {
        penumbraWS = pcfKernelWS;//bias 跟着同一个核半径走，保持"核大→深度偏移也大"
        radiusUV = pow(penumbraWS * worldToUV2, _DirectionalPCSSPenumbraPow);
    }
    //至少1纹素 + 不超过本tile剩余空间：整体等比缩放（替代逐样本clamp，且不会破坏圆的形状）
    radiusUV = PCSSFitKernelUV(radiusUV, roomToTile, texelUV);

    //③ 变半径 PCF：bias 同样随核半径与斜率变化
    float biasPCFWS = baseBiasWS + (texelWorld + penumbraWS) * slope * _DirectionalPCSSSlopeBias;
    //保险丝：最多偏到"到光源距离的一半"，避免斜率估歪时把阴影整块抹掉。
    //(原来用 depthRange*0.05 —— 它正比于级联尺寸，细级联被截得厉害)
    biasPCFWS = min(biasPCFWS, receiverDist * 0.5);
    int pcfSamples = clamp(_DirectionalPCSSSamples, 8, PCSS_MAX_SAMPLES);
    float shadow = 0.0;
    for (int j = 0; j < pcfSamples; j++)
    {
        float2 offset = RotatePCSSSample(pcssDisk[j], sinCos) * radiusUV;
        float2 uv = clamp(positionSTS.xy + offset, uvClampMin, uvClampMax);
        shadow += PCSSShadowed(SamplePCSSDepth(uv), receiverDist, biasPCFWS, depthRange) ? 0.0 : 1.0;
    }
    return shadow / pcfSamples;
}

//=========================================================================================
//====== 半影mask：判定"这个像素到底要不要交给PCSS" ======
//=========================================================================================
//返回值就是 mask 该写的值：0 = 全遮、1 = 全亮、0.5 = 半影带（交给PCSS）。
//必须**两步**判，只看半影宽度是不够的：
//  ① 迷你 blocker search（半径/bias 都取和 PCSS 的 blocker search 同一套，只是采样点少很多）
//     ①-a 一处遮挡都没搜到 ⇒ 用"中心点二值判定"的结果（**不能**无脑当受光：blocker 的 bias 很宽，
//          矮遮挡物搜不出来，无脑返回1会把它们的阴影整块抹掉）
//     ①-b 估出本地半影宽度 `penumbraWorld`（公式和 PCSS 里一模一样）
//  ② 半影够粗(>阈值)时，再用这个宽度当半径横向探一圈：中心和邻居的"明暗结论"全一致 ⇒
//     我离阴影边界比一个半影还远 ⇒ 我不在半影里 ⇒ 直接二值。
//     这一步是必需的：PCSS 的半影公式在**阴影正中间**也会给出很大的值（那里遮挡物离接收面远、
//     深度差大），但内部根本不需要PCSS —— 它只会得到0，纯浪费。只有"边界探测"能把内部排除掉。
//  （两次用到的偏移量都是**世界长度**，换算成 uv 必须分轴：worldToUV2）
float EstimateShadowBandValue (Surface surfaceWS, ShadowData global, DirectionalShadowData directional,
    float worldPerMaskTexel)
{
    int cascadeCount = max(_CascadeCount, 1);
    int cascadeIndex = global.cascadeIndex;
    int tileIndex = directional.tileIndex;//已含级联偏移（见 GetDirectionalShadowData）

    //光空间坐标：法线偏移 + 该级联的 world→light 矩阵（和 GetCascadedShadow 一致）
    float3 nGeo = PCSSBiasNormal(surfaceWS);
    float3 positionSTS = mul(_DirectionalShadowMatrices[tileIndex],
        float4(surfaceWS.position + PCSSNormalBiasOffset(cascadeIndex, nGeo), 1.0)).xyz;

    float uvWidth = 1.0 / cascadeCount;
    float uvHeight = max(_ShadowAtlasSize.x, 1.0) * uvWidth / max(_ShadowAtlasSize.z, 1.0);
    float2 uvSize = float2(uvWidth, uvHeight);
    float2 uvMin = float2(tileIndex % cascadeCount, tileIndex / cascadeCount) * uvSize;
    float2 halfTexel = _ShadowAtlasSize.yw * 0.5;
    float2 uvClampMin = uvMin + halfTexel;
    float2 uvClampMax = uvMin + uvSize - halfTexel;

    float orthoWidth = max(_CascadeData[cascadeIndex].z, 1e-4);
    float depthRange = max(_CascadeData[cascadeIndex].w, 1e-4);
    float texelWorld = orthoWidth / max(_ShadowAtlasSize.x * uvWidth, 1e-4);
    float2 worldToUV2 = float2(uvWidth, uvHeight) / orthoWidth;

    float receiverDist = PCSSDepthToNear(positionSTS.z) * depthRange;
    float baseBiasWS = _DirectionalPCSSPadding * depthRange;
    float nl = saturate(dot(nGeo, _DirectionalPCSSLightDir));
    float slope = min(sqrt(max(0.0, 1.0 - nl * nl)) / max(nl, 0.1), 4.0);//tanθ，clamp防掠射角爆炸

    //① 迷你 blocker search：半径和bias都和 PCSS 的 blocker search 一致 ⇒ 我找到的 blocker 就是它找到的那些
    //   （3×3，轴向0.67R、对角0.94R，大致铺满搜索半径）
    float searchWorld = max(_DirectionalPCSSSearchRadius, texelWorld);
    float searchStepWorld = searchWorld / 1.5;
    float biasBlockerWS = baseBiasWS + (texelWorld + searchWorld) * slope * _DirectionalPCSSSlopeBias;
    float blockerSum = 0.0;
    int blockerCount = 0;
    [unroll]
    for (int y = -1; y <= 1; y++)
    {
        [unroll]
        for (int x = -1; x <= 1; x++)
        {
            float2 uv = clamp(positionSTS.xy + float2(x, y) * searchStepWorld * worldToUV2,
                uvClampMin, uvClampMax);
            float sampleDist = PCSSDepthToNear(SamplePCSSDepth(uv)) * depthRange;
            if (sampleDist + biasBlockerWS < receiverDist)
            {
                blockerSum += sampleDist;
                blockerCount++;
            }
        }
    }
    //中心点那一下的深度值（后面二值判定用）
    float2 uvCenter = clamp(positionSTS.xy, uvClampMin, uvClampMax);
    float centerDist = PCSSDepthToNear(SamplePCSSDepth(uvCenter)) * depthRange;

    //①-b 没有搜到任何遮挡物：**直接采用中心点的二值判定**，不能无脑返回1（受光）。
    //     因为 blocker 的 bias 很宽（≈0.6~1.6m 的深度容差），矮遮挡物（0.5m高的箱子，深度差只有
    //     高度×sin仰角）根本搜不出来 —— 无脑返回1会把它们的阴影整块抹掉。
    //     PCSS 遇到这种情况会退回"PCF核下限"、照样是暗的，所以这里用中心点的紧判定与它对齐。
    if (blockerCount == 0)
    {
        float biasNoBlockerWS = baseBiasWS + (texelWorld * 2.0) * slope * _DirectionalPCSSSlopeBias;
        return (centerDist + biasNoBlockerWS < receiverDist) ? 0.0 : 1.0;
    }

    //② 本地半影宽度（和 PCSS 同一个公式）；细于阈值就说明"PCSS给出来也就是个硬边" ⇒ 直接二值
    float blockerDist = blockerSum / blockerCount;
    float ratio = saturate((receiverDist - blockerDist) / max(_DirectionalPCSSPenumbraRef, 1e-5));
    float penumbraWorld = ratio * _DirectionalPCSSPenumbraMaxWorld;

    //中心点的 bias：和 PCSS 的 PCF bias 同口径（padding + (本纹素 + 本地半影) × 坡度起伏），
    //这样 mask 写出去的 0/1 和 PCSS 在带子里算出来的值才是同一套东西（紧过头会在亮区留黑点）
    float biasCenterWS = baseBiasWS + (texelWorld + penumbraWorld) * slope * _DirectionalPCSSSlopeBias;
    float centerLit = (centerDist + biasCenterWS < receiverDist) ? 0.0 : 1.0;
    if (penumbraWorld <= MASK_BAND_MIN_TEXELS * max(worldPerMaskTexel, 1e-6))
    {
        return centerLit;
    }

    //③ 边界探测：拿"本地半影宽度"当半径，把中心和邻居比明暗（两边用同一套bias ⇒ 系统偏差互相抵消）
    float centerShadowed = (centerDist + biasCenterWS < receiverDist) ? 1.0 : 0.0;
    [unroll]
    for (int y = -1; y <= 1; y++)
    {
        [unroll]
        for (int x = -1; x <= 1; x++)
        {
            float2 uv = clamp(positionSTS.xy + float2(x, y) * penumbraWorld * worldToUV2,
                uvClampMin, uvClampMax);
            float sampleDist = PCSSDepthToNear(SamplePCSSDepth(uv)) * depthRange;
            float sampleShadowed = (sampleDist + biasCenterWS < receiverDist) ? 1.0 : 0.0;
            if (sampleShadowed != centerShadowed)
            {
                return 0.5;//边界就在一个半影宽度之内 ⇒ 这才是真正需要PCSS的地方
            }
        }
    }
    return centerLit;//边界比一个半影还远（在亮处、或在阴影正中间）⇒ 这个像素就是纯0/1
}

//每2x2屏幕像素共享的泊松盘旋转角（IGN式小参数哈希，避免大整数sin精度退化）
float2 GetPCSSRotation (Surface surfaceWS)
{
    #if defined(_DIRECTIONAL_PCSS)
        float4 clipPos = TransformWorldToHClip(surfaceWS.position);
        float2 screenUV = clipPos.xy / clipPos.w * 0.5 + 0.5;
        float2 blockIdx = floor(screenUV * _ScreenParams.xy * 0.5);
        float rotAngle = frac(52.9829189 * frac(0.06711056 * blockIdx.x + 0.00583715 * blockIdx.y)) * 6.2831853;
        float s, c;
        sincos(rotAngle, s, c);
        return float2(s, c);
    #else
        return float2(0.0, 1.0);
    #endif
}

//主光一定是第一行tile（灯起始偏移为0），据此决定是否走PCSS
float SampleDirectionalShadowFiltered (float3 positionSTS, int tileIndex, float2 sinCos, bool mainLight, float slope)
{
    #if defined(_DIRECTIONAL_PCSS)
        if (mainLight)
        {
            return PCSSDirectionalShadow(positionSTS, tileIndex, sinCos, slope);
        }
    #endif
    return FilterDirectionalShadow(positionSTS);
}

float GetCascadedShadow(DirectionalShadowData directional, ShadowData global, Surface surfaceWS)
{
    // tileIndex = 光源在atlas的起始偏移(cascadeCount * lightIndex) + 当前级联索引(cascadeIndex)
    // CPU端ReserveDirectionalShadows的.y是每个灯的起始偏移，存入Light.hlsl的_DirectionalLightShadowData[lightIndex].y，，，
    //      RenderDirectionalShadows按tileIndex索引写入dirShadowMatrices[tileIndex]
    // GPU端Light.hlsl里GetDirectionalShadowData从_DirectionalLightShadowData[lightIndex].y + cascadeIndex 还原tileIndex，用它取对应矩阵，保证矩阵数组索引一一对应
    //主光=第一行tile(灯起始偏移为0)。只有它走PCSS，且用PCSS自己的法线偏移/几何法线/光方向
    bool mainLight = false;
    float3 nGeo = float3(0.0, 0.0, 1.0);
    float nl = 1.0;
    float slope = 0.0;
    float2 pcssSinCos = float2(0.0, 1.0);
    #if defined(_DIRECTIONAL_PCSS)
        //bias 用的法线：稳定的内插法线，翻正到朝光一侧（不再用屏幕导数，避免画面边缘算歪）
        nGeo = PCSSBiasNormal(surfaceWS);
        nl = saturate(dot(nGeo, _DirectionalPCSSLightDir));
        slope = min(sqrt(max(0.0, 1.0 - nl * nl)) / max(nl, 0.1), 4.0);//tanθ，clamp防掠射角爆炸
        mainLight = directional.tileIndex < _CascadeCount;
        if (mainLight)
        {
            pcssSinCos = GetPCSSRotation(surfaceWS);//每2x2屏幕像素共享的旋转角
        }
    #endif

    float3 normalBias = (mainLight ?
        PCSSNormalBiasOffset(global.cascadeIndex, nGeo) :
        surfaceWS.interpolatedNormal * (directional.normalBias * _CascadeData[global.cascadeIndex].y));//y是tile纹素在世界空间中的长度，沿法线偏移避免锯齿
    float3 positionSTS = mul(_DirectionalShadowMatrices[directional.tileIndex],float4(surfaceWS.position +normalBias, 1.0)).xyz;
    float shadow = SampleDirectionalShadowFiltered(positionSTS, directional.tileIndex, pcssSinCos, mainLight, slope);//pcf 或 PCSS 采样
    
    if (global.cascadeBlend < 1.0)//在两个级联的交界混合区域
    {
        normalBias = (mainLight ?
            PCSSNormalBiasOffset(global.cascadeIndex + 1, nGeo) :
            surfaceWS.interpolatedNormal * (directional.normalBias * _CascadeData[global.cascadeIndex + 1].y));
        positionSTS = mul(_DirectionalShadowMatrices[directional.tileIndex + 1],float4(surfaceWS.position +normalBias, 1.0)).xyz;
        shadow = lerp(SampleDirectionalShadowFiltered(positionSTS, directional.tileIndex + 1, pcssSinCos, mainLight, slope), shadow, global.cascadeBlend);
    }
    return shadow;
}

float GetBakedShadow(ShadowMask mask, int channel)//直接采样到的烘焙值
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
float GetBakedShadow (ShadowMask mask, int channel, float strength) {//采样的烘焙值，用光源的阴影强度调整过的
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

//世界坐标 → 屏幕UV：和延迟Pass重建世界坐标用的那套翻转互为逆运算（见 CameraRendererPasses.hlsl 的 DeferredLightPassFragment）
float2 ScreenSpaceShadowUV (float3 positionWS)
{
    float4 positionCS = mul(UNITY_MATRIX_VP, float4(positionWS, 1.0));
    float2 uv = positionCS.xy / positionCS.w * 0.5 + 0.5;
    #if UNITY_UV_STARTS_AT_TOP
        uv.y = 1.0 - uv.y;
    #endif
    return uv;
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
    if (directional.strength * global.strength <= 0.0)//新写法，物体离相机太远超出最大级联距离，或，像素在最外层级联外边缘强度已经降到0，这个实际上是“实时阴影完全不可用”的情况，就采样烘焙的shadow
    {
        shadow = GetBakedShadow(global.shadowMask, directional.shadowMaskChannel, abs(directional.strength));//这里的abs，是cullingResults.GetShadowCasterBounds为false的情况
    }
    else//物体与相机距离在最大级联距离之内，并且，如果在最外层衰减强度还没衰减到0，就混合采样实时和烘焙阴影     有阴影且没衰减，就是实时阴影；有阴影有衰减，就是实时与烘焙和混合
    {
        //屏幕空间阴影（只有延迟渲染会开）：直接采样那张图，不再逐像素算PCSS。
        //只有主光做了屏幕空间阴影图 → 用 tileIndex 判断（主光的tileIndex < 级联数，和其它地方口径一致）。
        //两条路输出的都是"纯实时"的阴影，所以下面的烘焙混合、强度衰减照旧。
        if (_ScreenSpaceShadowEnabled > 0.5 && directional.tileIndex < _CascadeCount)
        {
            shadow = SAMPLE_TEXTURE2D_LOD(_ScreenSpaceShadowTex, sampler_linear_clamp,
                ScreenSpaceShadowUV(surfaceWS.position), 0).r;
        }
        else
        {
            shadow = GetCascadedShadow(directional, global, surfaceWS);
        }
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
            	//先确认片元真的也落在“下一级联”的球里才向它过渡，否则留在本级联：
            	//画面左右两侧的地面点常会先碰到当前级联球边缘、却还没进入下一级联球，
            	//此时直接去采下一级联的shadowmap属于越界采样，会出现不该有的环形假阴影。
            	float4 nextSphere = _CascadeCullingSpheres[i + 1];
            	data.cascadeBlend =
            		DistanceSquared(surfaceWS.position, nextSphere.xyz) < nextSphere.w ? fade : 1.0;
            }
            break;
        }
    }
    if (i == _CascadeCount && _CascadeCount > 0)//起码保证有级联
    {
        data.strength = 0.0;//太远的地方，超出最后一个级联，强度设为0，直接避免采样
    }
    //级联混合模式（0=Hard 1=Soft 2=Dither）：原来是三个编译变体，现在用 uniform 在运行时分支。
    //理由见 CBUFFER 里 _CascadeBlendMode 的注释：它是全局设置，分支不产生分歧，但能省下 3 倍的变体。
    else if (_CascadeBlendMode == 2 && data.cascadeBlend < surfaceWS.dither)//Dither：按屏幕噪声丢掉一部分过渡像素
    {
        i += 1;
    }
    //Hard(0) 与 Dither(2) 都不做软混合的两次采样（只有 Soft 才保留 0~1 的 blend 因子）→ 强制为1，避免为此采样两次
    if (_CascadeBlendMode != 1)
    {
        data.cascadeBlend = 1.0;
    }
    data.cascadeIndex = i;
    return data;
}

//------点光源和聚光灯--------//

struct OtherShadowData {
    float strength;//目前是，只要阴影强度为正，就调用已烘焙的shadow
    int tileIndex;
    bool isPoint;
    int shadowMaskChannel;
    float3 lightPositionWS;//透视灯光的法线偏差只有在固定距离1上才是正确的。要根据与光平面的距离进行缩放，so需要知道世界空间的光线位置和光方向
    float3 lightDirectionWS;//立方体贴图的面作为瓦片存储在图集中，因此无法使用标准的立方体贴图采样。必须自己确定合适的采样面,,,需要知道处理的是否是点光源以及表面到光源的方向
    float3 spotDirectionWS;
};

float SampleOtherShadowAtlas (float3 positionSTS, float3 bounds) {
    positionSTS.xy = clamp(positionSTS.xy, bounds.xy, bounds.xy + bounds.z);
    return SAMPLE_TEXTURE2D_SHADOW(_OtherShadowAtlas, SHADOW_SAMPLER, positionSTS);
}

float FilterOtherShadow (float3 positionSTS, float3 bounds) {
    #if defined(SHADOW_FILTER_SETUP)
        real weights[SHADOW_FILTER_SAMPLES];
        real2 positions[SHADOW_FILTER_SAMPLES];
        float4 size = _OtherShadowAtlasSize.yyxx;//other是正方形图集，x=边长,y=1/边长，yyxx→(1/s,1/s,s,s)
        SHADOW_FILTER_SETUP(size, positionSTS.xy, weights, positions);
        float shadow = 0;
        for (int i = 0; i < SHADOW_FILTER_SAMPLES; i++) {
            shadow += weights[i] * SampleOtherShadowAtlas(float3(positions[i].xy, positionSTS.z), bounds);  
        }
        return shadow;
    #else
        return SampleOtherShadowAtlas(positionSTS, bounds);
    #endif
}

//点光源6个cubemap面对应的光平面法线，指向光源方向（和spotDirectionWS语义一致）
static const float3 pointShadowPlanes[6] = {
    float3(-1.0, 0.0, 0.0),  // +X面
    float3(1.0, 0.0, 0.0),   // -X面
    float3(0.0, -1.0, 0.0),  // +Y面
    float3(0.0, 1.0, 0.0),   // -Y面
    float3(0.0, 0.0, -1.0),  // +Z面
    float3(0.0, 0.0, 1.0)    // -Z面
};

///其他光源的实时阴影（点光选对面+tile，聚光直接用基准tile）
float GetOtherShadow(OtherShadowData other, ShadowData global, Surface surfaceWS) {
    int tileIndex = other.tileIndex;
    float3 lightPlane = other.spotDirectionWS;
    if (other.isPoint) {
        int faceOffset = CubeMapFaceID(-other.lightDirectionWS); // 物体在光源的哪个方向→对应的cubemap面
        tileIndex += faceOffset;                                    // 基准tile + 面偏移 = 正确的6个子tile之一
        lightPlane = pointShadowPlanes[faceOffset];                // 点光没有spotDirection，用面对应的法线替代
    }
    float4 tileData = _OtherShadowTiles[tileIndex];                // 用修正后的tileIndex取边界和bias
    float3 surfaceToLight = other.lightPositionWS - surfaceWS.position;
    float distanceToLightPlane = dot(surfaceToLight, lightPlane);
    float3 normalBias = surfaceWS.interpolatedNormal * (distanceToLightPlane * tileData.w);
    float4 positionSTS = mul(_OtherShadowMatrices[tileIndex], float4(surfaceWS.position + normalBias, 1.0));
    return FilterOtherShadow(positionSTS.xyz / positionSTS.w, tileData.xyz);//因为是透视投影所以除w
}

float GetOtherShadowAttenuation(OtherShadowData other, ShadowData global, Surface surfaceWS) {
    #if !defined(_RECEIVE_SHADOWS)
        return 1.0;
    #endif
	
    float shadow;
    //这里有疑问，就去看上边GetDirectionalShadowAttenuation
    if (other.strength * global.strength <= 0.0) {//对级联阴影和其他光源的阴影，用统一的距离淡化，不能出现“远处没有级联阴影而还有其他灯光的阴影的情况”
        shadow = GetBakedShadow(global.shadowMask, other.shadowMaskChannel, abs(other.strength));
    }
    else {
        shadow = GetOtherShadow(other, global, surfaceWS);
        shadow = MixBakedAndRealtimeShadows(global, shadow, other.shadowMaskChannel, other.strength);//这个函数和什么灯光类型无关，因此这也可以用
    }
    return shadow;
}



#endif