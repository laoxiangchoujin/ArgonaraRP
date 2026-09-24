#ifndef CUSTOM_SSGI_INCLUDED
#define CUSTOM_SSGI_INCLUDED

//屏幕空间间接光（SSGI）的 shader 代码：四个 pass（追踪 / 时间累积 / 横竖两趟双边）的函数体都写在这里。
//由 ScreenSpaceIndirectDiffuse.shader 的 HLSLINCLUDE include；C# 侧的调用顺序见 ScreenSpaceIndirectDiffuse.cs。
//⚠️ `_SSGITex` 和 `_SSGIIntensity` 的声明在 GI.hlsl（物体着色那边也要用），这里**不要再声明一遍**。
//
//口径（C# 那边也按这个约定调）：
//  追踪输出 = (rgb = 间接漫反射辐照度（只统计**命中**的射线）、a = 可信度 = 命中率 × 屏幕边缘淡出)
//  ⚠️ 没命中的射线**什么都不贡献**（原来塞 SH 探针兜底 ⇒ 遮挡处也会被照亮 = 漏光；现在靠 a 退回烘焙）
//  ⚠️ 和 CGBull 不同：它把"眼空间深度"塞在 a 里给双边滤波用，我们改成 a = 可信度
//     （物体着色的 GetGI 就按 `lerp(烘焙, rgb, a)` 混）；滤波/重投影要深度时直接采 _CameraDepthTexture。

//=========================== 纹理 ===========================
//GI 图自己的纹素尺寸：xy = 1/宽、1/高（zw = 宽、高），半分辨率，由 C# 上传
float4 _SSGITexelSize;
//每趟的"当前输入"：时间累积读本帧追踪结果、横竖之间倒手，都由 C# 改绑它
TEXTURE2D(_SSGISourceTex);
//（C# 借的两张临时图不需要在这里声明：本文件不直接采样它们，只由 C# 当渲染目标用）

//=========================== 矩阵 / 随机 / HiZ ===========================
//上一帧 VP（未抖动）：时间累积做重投影用
float4x4 _SSGIPrevViewProj;
//本帧随机种子：xy = Halton 偏移（射线方向每帧都要变），z = 这帧丢掉历史（1 = 别混历史）
float4 _SSGIRandomOffset;
//本帧 TAA 抖动（xy = **UV 单位**，z/w 未用）：时间累积重投影出的历史 UV 要把它加回去（和 TAA 那行同一个道理）
float4 _SSGIJitter;
//STBN 时空蓝噪声图集（512×512 = 8×8 个 64×64 切片）+ "配没配"开关 + 本帧用第几片。
//没配时 C# 会绑白图并把开关设 0 ⇒ 下面退回程序化的 R2 序列（见 TracePassFragment）。
TEXTURE2D(_SSGIBlueNoise);
float _SSGIBlueNoiseEnabled;
float _SSGISliceIndex;

//Hi-Z（复用 HierarchicalZ 的那张全分辨率图）：追踪按 mip 大步跳
TEXTURE2D(_HiZTex);
int _MaxHiZMipLevel;
float _HiZEnabled;

//=========================== 参数（对应 ScreenSpaceIndirectDiffuseSettings）===========================
float _SSGIRayCount;
float _SSGIRayLength;
float _SSGIStepCountLimit;
float _SSGIThickness;
float _SSGIScreenFade;
float _SSGITemporalWeight;
float _SSGITemporalScale;
float _SSGIMotionBlendScale;//"重投影位移越大越信当前帧"的放大系数（没有 MV 时的代偿，见 TemporalPassFragment）
float _SSGIBlurRadius;
float _SSGIDebugIndirect;
float _SSGIOtherLightLimit;//命中点参与着色"其他光源"（点光/聚光）的最大数量（0 = 不参与）

//=========================== 追踪用的小工具 ===========================
//（名字都带 Ssgi 前缀：以后要和 SSR 那套抽公共库时不至于撞名）

float SsgiLuminance (float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

//亮度软压缩 / 还原（卡特莱克防 firefly 那招）：单根射线先压到 (0,1) 再平均，
//平均完还原 ⇒ 单根的值原样返回，只有"个别超亮命中"在平均时被压小。
float3 SsgiCompress (float3 c) { return c / (1.0 + SsgiLuminance(c)); }
float3 SsgiUncompress (float3 c) { return c / max(1.0 - SsgiLuminance(c), 1e-3); }

//视空间点 → 屏幕 UV(0~1)。投影翻转交给 _ProjectionParams.x（渲染到 RT 时它自动为 -1）
float2 SsgiViewToScreenUV (float3 posVS)
{
    float4 posCS = TransformWViewToHClip(posVS);
    return float2(posCS.x, posCS.y * _ProjectionParams.x) / posCS.w * 0.5 + 0.5;
}

//沿 dirVS 用 **Hi-Z 大步跳**找命中（步进规则和 SSR 那套一致：安全就升档、可疑就降档、mip0 + 厚度判命中）。
//命中给 hitUV（屏幕 UV）；hitZ 是命中点的视空间深度（米），调试用。
bool SsgiTraceRayWithHiZ (float3 startVS, float3 dirVS, float3 normalVS, out float2 hitUV, out float hitZ)
{
    hitUV = 0; hitZ = 0;
    //Hi-Z 没配好（_HiZTex 是 1×1 黑图）时直接当"没命中" ⇒ 全部走 SH 兜底：不会崩，只是没有屏幕空间 GI
    if (_HiZEnabled < 0.5)
        return false;

    //起点沿法线抬起一点，避免"射线打到自己所在的那个面"（自交）
    float3 rayStartVS = startVS + normalVS * 0.01;

    //朝相机飞的射线可能捅到相机背后（UV 的透视除法会炸、深度会跨过 0）⇒ 先截断到近平面
    float maxDistance = _SSGIRayLength;
    if (dirVS.z > 1e-6)
    {
        float endVSZ = rayStartVS.z + dirVS.z * maxDistance;
        float nearVSZ = -_ProjectionParams.y;//近平面的视空间 z（负值）
        if (endVSZ > nearVSZ)
            maxDistance = max((nearVSZ - rayStartVS.z) / dirVS.z, 0.0);
    }

    float2 startUV = SsgiViewToScreenUV(rayStartVS);
    float3 endVS = rayStartVS + dirVS * maxDistance;
    float2 endUV = SsgiViewToScreenUV(endVS);

    float2 bufferSize = _CameraBufferSize.zw;//(宽, 高)
    if (length(startUV - endUV) < min(1.0 / bufferSize.x, 1.0 / bufferSize.y))//两点几乎重合：给终点补 1 像素
        endUV += 1.0 / bufferSize;

    //屏幕空间等分：深度用 1/z（透视下沿屏幕上的直线插值时 1/z 是线性的）
    float2 deltaPixels = (endUV - startUV) * bufferSize;
    float screenSpan = max(abs(deltaPixels.x), abs(deltaPixels.y));
    int baseStepCount = max((int)ceil(screenSpan), 1);//基准步长 = 1 个全分辨率像素
    float2 deltaUV = (endUV - startUV) / baseStepCount;
    float start1bz = 1.0 / -rayStartVS.z;
    float end1bz = 1.0 / -endVS.z;
    float delta1bz = (end1bz - start1bz) / baseStepCount;

    float2 currentUV = startUV;
    float current1bz = start1bz;
    //起始抖动（用本项目现成的 IGN + 每帧种子）：不然同一像素每帧都踩同一个位置，会有固定走样
    float jitter = InterleavedGradientNoise(startUV * bufferSize + _SSGIRandomOffset.xy * 64.0, 0);
    currentUV += jitter * deltaUV;
    current1bz += jitter * delta1bz;

    float mipLevel = 0.0;
    [loop]
    for (int i = 0; i < (int)_SSGIStepCountLimit; i++)
    {
        float stepScale = exp2(mipLevel);//每升一级，步长翻倍（一格的宽度）
        //这一步最多走到射线终点（跨过去就夹到正好落在终点）
        float stepsToEnd = (abs(delta1bz) > 1e-12) ? (end1bz - current1bz) / delta1bz : 1e6;
        bool atRayEnd = stepsToEnd <= stepScale;
        if (atRayEnd)
            stepScale = max(stepsToEnd, 0.0);

        float2 nextUV = currentUV + deltaUV * stepScale;
        float next1bz = current1bz + delta1bz * stepScale;
        float rayFarZ = max(1.0 / current1bz, 1.0 / next1bz);//这一步的**远端**深度（判据要用它才保守）

        if (nextUV.x < 0 || nextUV.x > 1 || nextUV.y < 0 || nextUV.y > 1)
        {
            //走出屏幕：先退档再判死（大步时第一步就出屏很常见，别整条放弃）
            if (mipLevel > 0.5) { mipLevel -= 1.0; continue; }
            return false;
        }
        if (rayFarZ <= 0)
            return false;//越过相机平面（背后那块画面不在屏幕上）

        //采样点取这一步的**中点**；每步采"中点 + 末端"两格（只采一格会漏掉半格 ⇒ 远处条纹状缺失）
        float2 sampleUV = currentUV + deltaUV * (0.5 * stepScale);
        float sampleZ = 1.0 / (current1bz + 0.5 * delta1bz * stepScale);
        float rawMid = SAMPLE_TEXTURE2D_LOD(_HiZTex, sampler_point_clamp, sampleUV, mipLevel).r;
        float rawEnd = SAMPLE_TEXTURE2D_LOD(_HiZTex, sampler_point_clamp, nextUV, mipLevel).r;
        //这一格（2^mip × 2^mip 个全分辨率像素）里"离相机最近"的表面
        float surfaceZ = LinearEyeDepth(max(rawMid, rawEnd), _ZBufferParams);

        if (rayFarZ > surfaceZ)//这一步的远端越过了这块里最近的表面 ⇒ 可能跨过了它
        {
            if (mipLevel > 0.5) { mipLevel -= 1.0; continue; }//还有更细的级：降档、退回来重走
            if (abs(surfaceZ - sampleZ) < _SSGIThickness)//最细一级 + 面落在采样点 ±一个厚度之内 ⇒ 命中
            {
                hitUV = sampleUV;
                hitZ = surfaceZ;
                return true;
            }
        }
        else
        {
            mipLevel = min(mipLevel + 1.0, (float)_MaxHiZMipLevel);//这一整块都没东西 ⇒ 升档、大步走
        }

        if (atRayEnd)
            return false;
        currentUV = nextUV;
        current1bz = next1bz;
    }
    return false;
}

//Shirley 同心圆盘 → cosine 加权半球方向（世界空间）：低差异、比随机方向噪点少
float3 SsgiCosineHemisphere (float2 u, float3 normalWS)
{
    float2 u2 = u * 2.0 - 1.0;
    if (u2.x == 0.0 && u2.y == 0.0)//退化：就朝法线方向（也顺手避开下面的除法）
        return normalWS;

    float r, theta;
    //⚠️ 这里**不能**给分母套 max(...,1e-6)：`abs(u2.x) > abs(u2.y)` 已经保证 u2.x ≠ 0；
    //   另一支同理（u2.y = 0 只可能出现在 u2 = 0，上面已经返回了）。套了 max 反而会让 u2.y < 0 的
    //   那半个区域算成一团乱数（角度被推到极大）⇒ 半球方向分布错掉。
    if (abs(u2.x) > abs(u2.y))
    {
        r = u2.x;
        theta = PI * 0.25 * (u2.y / u2.x);
    }
    else
    {
        r = u2.y;
        theta = PI * 0.5 - PI * 0.25 * (u2.x / u2.y);
    }
    float2 disk = r * float2(cos(theta), sin(theta));
    float3 local = float3(disk, sqrt(saturate(1.0 - dot(disk, disk))));

    //局部（z 朝上）→ 世界：拿法线当 z 轴
    float3 up = abs(normalWS.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangent = normalize(cross(up, normalWS));
    float3 bitangent = cross(normalWS, tangent);
    return normalize(tangent * local.x + bitangent * local.y + normalWS * local.z);
}

//命中点收到的"其他光源"（点光/聚光）辐照度：只取**最近的 N 盏**（`_SSGIOtherLightLimit`，0 = 关）。
//做法：先扫全部灯、只算距离平方（超出这盏灯范围的直接跳过），把最近的塞进一张**固定 8 槽**的有序表
//（槽位全是编译期常量、都在寄存器里 ⇒ 不做动态索引、不会 spill 到 local memory），再对前 limit 槽做完整着色。
//（不用 `_LIGHTS_PER_OBJECT` 那套逐物体灯表：那是逐 draw 的，全屏 pass 里全是 0，没意义）
float3 SsgiOtherLightIrradiance (float3 hitPosWS, float3 hitNormalWS, Surface hit, ShadowData shadowData)
{
    int limit = min((int)_SSGIOtherLightLimit, 8);
    if (limit <= 0)
        return 0;

    const float farAway = 1e30;
    float bestDist[8];
    int bestIndex[8];
    [unroll]
    for (int s = 0; s < 8; s++)
    {
        bestDist[s] = farAway;
        bestIndex[s] = 0;
    }

    int count = GetOtherLightCount();
    for (int i = 0; i < count; i++)
    {
        float3 toLight = _OtherLightPositions[i].xyz - hitPosWS;
        float distSqr = dot(toLight, toLight);
        //超出这盏灯的范围（`_OtherLightPositions[i].w` = 1/range²）⇒ 贡献是 0，不用参与排序也不用算光照
        if (distSqr * _OtherLightPositions[i].w >= 1.0)
            continue;

        //插入有序表："带着当前值依次往后挤"（全常量索引）
        float carryDist = distSqr;
        int carryIndex = i;
        [unroll]
        for (int s = 0; s < 8; s++)
        {
            if (carryDist < bestDist[s])
            {
                float tmpDist = bestDist[s];
                int tmpIndex = bestIndex[s];
                bestDist[s] = carryDist;
                bestIndex[s] = carryIndex;
                carryDist = tmpDist;
                carryIndex = tmpIndex;
            }
        }
    }

    float3 irradiance = 0;
    [unroll]
    for (int s = 0; s < 8; s++)
    {
        if (s >= limit || bestDist[s] >= farAway)//到上限了、或者这一槽是空的（在范围内的灯不够 limit 盏）
            break;
        Light light = GetOtherLight(bestIndex[s], hit, shadowData);
        irradiance += light.color * saturate(dot(hitNormalWS, light.direction)) * light.attenuation;
    }
    return irradiance;
}

//命中点的公共数据（深度/法线一次取齐）：背面剔除和着色都用它，同一个像素不采两遍
struct SsgiHit
{
    float3 positionWS;
    float3 normalWS;    //着色法线（GBuffer2，含法线图扰动）：只给着色用
    float eyeDepth;
    bool frontFacing;   //射线是不是从这条面的**正面**打过来的（false = 假命中）
};

//取齐命中点数据，并判"这一球是不是从背面穿过去的"。
//判据用**几何面法线**（深度邻居重构，不含法线图扰动），和 SSR 的 IsHitFrontFacing 同一个道理：
//着色法线在法线贴图花的地方会把"正面"误判成"背面"（反之也有）⇒ 那地方会闪、会漏光。
SsgiHit SsgiLoadHit (float2 hitUV, float3 dirVS)
{
    SsgiHit hit;
    float rawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, hitUV);
    float3 shadingNormalWS = normalize(SAMPLE_TEXTURE2D_LOD(_GBuffer2, sampler_point_clamp, hitUV, 0).xyz * 2.0 - 1.0);
    hit.positionWS = ScreenSpaceWorldPosFromDepth(hitUV, rawDepth);
    hit.normalWS = shadingNormalWS;
    hit.eyeDepth = LinearEyeDepth(rawDepth, _ZBufferParams);

    if (rawDepth < 0.00001)//天空/无效像素：没有面可判 ⇒ 不剔除
    {
        hit.frontFacing = true;
        return hit;
    }

    float3 geometricWS = ScreenSpaceGeometricNormal(hit.positionWS, hit.eyeDepth, shadingNormalWS, hitUV);
    float3 geometricVS = normalize(mul((float3x3)UNITY_MATRIX_V, geometricWS));
    //< 0 = 射线从正面进入（同 SSR）；> 0 = 从背面穿过 ⇒ 假命中
    hit.frontFacing = dot(dirVS, geometricVS) < 0.0;
    return hit;
}

//命中点着色（第一版）：命中点的 albedo × 收到的直接光（主光 + 最近的 N 盏点光/聚光，都带阴影）。
//为什么**不**采 GBuffer4（emission + indirect）：它里面已经含那个点自己的间接光 ⇒ 当"射出的光"用会把间接光算两遍
//（真要 emission 得单独存一张图，或者以后做"只含直接光的拷贝"）。
//（渲染层：命中点按"所有层都收"处理，没读 GBuffer3 的层掩码 —— 和延迟光照 pass 现状一致）
float3 SsgiShadeHit (SsgiHit hitData, float2 hitUV)
{
    float3 albedo = SAMPLE_TEXTURE2D_LOD(_GBuffer1, sampler_linear_clamp, hitUV, 0).rgb;
    float3 hitPosWS = hitData.positionWS;
    float3 hitNormalWS = hitData.normalWS;

    //伪造一个 Surface（阴影那套函数只要 position/normal/depth 这几个字段，其余给中立值）
    Surface hit;
    hit.position = hitPosWS;
    hit.depth = hitData.eyeDepth;
    hit.normal = hitNormalWS;
    hit.interpolatedNormal = hitNormalWS;
    hit.viewDirection = normalize(_WorldSpaceCameraPos - hitPosWS);
    hit.albedo = 0.0;
    hit.alpha = 1.0;
    hit.roughness = 0.0;
    hit.metallic = 0.0;
    hit.occlusion = 1.0;
    hit.renderingLayerMask = 0;
    hit.dither = 0.0;

    ShadowData shadowData = GetShadowData(hit);

    //收到的**辐照度**（≈ 出去的光 = albedo × 入射辐照度；和 SampleLightProbe 同口径）
    float3 irradiance = 0;
    //主光 = 第一个定向光（N·L × 阴影）
    if (GetDirectionalLightCount() > 0)
    {
        Light light = GetDirectionalLight(0, hit, shadowData);

        //⚠️ 阴影**自己算**，不用 `GetDirectionalLight` 里那条：它经 `GetDirectionalShadowAttenuation`，
        //   而那个函数开头是 `#if !defined(_RECEIVE_SHADOWS) return 1.0;` ⇒ 命中点到底吃不吃阴影取决于一个
        //   我们**控制不了**的全局关键字状态（对象材质的开关带起来的），"加 pragma 也没变化"应该就是这个。
        //   照 `ScreenSpacePCSS.shader` 的做法直接调 **`GetCascadedShadow`**：它**不带关键字门控**，
        //   且只算"实时级联阴影"、不混烘焙阴影/不做距离衰减 —— 正好是命中点需要的"这里被挡没被挡"。
        DirectionalShadowData dirShadow = GetDirectionalShadowData(0, shadowData);
        if (dirShadow.strength * shadowData.strength > 0.0)//超出最大阴影距离、或该光没有阴影强度 ⇒ 当作没有阴影
        {
            light.attenuation = GetCascadedShadow(dirShadow, shadowData, hit);
        }

        irradiance += light.color * saturate(dot(hitNormalWS, light.direction)) * light.attenuation;
    }
    //点光 / 聚光：最近的 N 盏（自带 range/spot 衰减 + 阴影）
    irradiance += SsgiOtherLightIrradiance(hitPosWS, hitNormalWS, hit, shadowData);

    //自发光（GT5）：命中点**自己发出的光** ⇒ **不乘它的 albedo**，所以单独加在最后。
    //系数 π：余弦加权采样下"辐照度 ≈ π × 平均辐亮度"，而 emission 是直接加在辐亮度上的一项
    //（物理口径；觉得亮/暗就用 _SSGIIntensity 整体调）
    float3 emission = SAMPLE_TEXTURE2D_LOD(_GBuffer5, sampler_linear_clamp, hitUV, 0).rgb;

    return albedo * irradiance + PI * emission;
}

//屏幕边缘淡出：屏幕外没有信息 ⇒ 越靠边越不可信（返回 0~1，当可信度用）
float SsgiScreenFade (float2 uv)
{
    float2 d = min(uv, 1.0 - uv);//到最近边的 UV 距离
    return saturate(min(d.x, d.y) / max(_SSGIScreenFade, 1e-4));
}

//=========================== 时间累积用的小工具 ===========================
//（和 TAA 那套是同一份写法，只是名字带 Ssgi 前缀：core 的 Color.hlsl 有 RGBToYCoCg、TAA 那边也有自己一份）

//YCoCg：亮度(Y) 和色度(Co/Cg) 分开 ⇒ 在色度上裁剪时，亮度的高频不会被色度偏差带跑
float3 SsgiRGBToYCoCg (float3 rgb)
{
    return float3(dot(rgb, float3(1, 2, 1)), dot(rgb, float3(2, 0, -2)), dot(rgb, float3(-1, 2, -1)));
}

float3 SsgiYCoCgToRGB (float3 ycocg)
{
    float y = ycocg.x * 0.25, co = ycocg.y * 0.25, cg = ycocg.z * 0.25;
    return float3(y + co - cg, y + cg, y - co - cg);
}

//把历史色朝"AABB 的中点"拉回来，直到落进盒子（软裁剪：连续变化，不会突然跳色）
float3 SsgiClipHistory (float3 history, float3 boxMin, float3 boxMax)
{
    float3 filtered = (boxMin + boxMax) * 0.5;
    float3 dir = filtered - history;
    dir = abs(dir) < (1.0 / 65536.0) ? (1.0 / 65536.0) : dir;//别除以 0
    float3 invDir = 1.0 / dir;
    float3 minIntersect = (boxMin - history) * invDir;
    float3 maxIntersect = (boxMax - history) * invDir;
    float3 enterIntersect = min(minIntersect, maxIntersect);
    float clipBlend = saturate(max(enterIntersect.x, max(enterIntersect.y, enterIntersect.z)));
    return lerp(history, filtered, clipBlend);
}

static const float2 SsgiOffsets3x3[9] =
{
    float2(-1, -1), float2(0, -1), float2(1, -1),
    float2(-1,  0), float2(0,  0), float2(1,  0),
    float2(-1,  1), float2(0,  1), float2(1,  1),
};

//=========================== 双边滤波用的小工具 ===========================

//场景法线（延迟读 GBuffer2；编码是 normal * 0.5 + 0.5）
float3 SsgiSceneNormal (float2 uv)
{
    return normalize(SAMPLE_TEXTURE2D_LOD(_GBuffer2, sampler_point_clamp, uv, 0).xyz * 2.0 - 1.0);
}

//双边的两个容差（第一版先写死，出问题再抽成设置）
static const float SsgiBlurDepthTolerance = 0.05;//深度**相对差**（占视距的比例）到这就不混了
static const float SsgiBlurNormalPower = 8.0;    //法线点积的幂：越大越只混"朝向接近"的

//双边权重 = 空间（高斯）× 深度接近 × 法线接近
float SsgiBilateralWeight (float2 sampleUV, float centerDepth, float3 centerNormal, float offsetTexels, float radius)
{
    float sampleDepth = LinearEyeDepth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, sampleUV), _ZBufferParams);
    float3 sampleNormal = SsgiSceneNormal(sampleUV);

    float sigma = max(radius * 0.5, 1.0);
    float spatial = exp(-(offsetTexels * offsetTexels) / (2.0 * sigma * sigma));
    //深度用**相对差**：远处同一条街的绝对深度差很大，只有相对差才稳
    float depthWeight = saturate(1.0 - abs(sampleDepth - centerDepth) / max(centerDepth * SsgiBlurDepthTolerance, 1e-3));
    float normalWeight = pow(saturate(dot(centerNormal, sampleNormal)), SsgiBlurNormalPower);
    return spatial * depthWeight * normalWeight;
}

//横/竖共用的双边滤波：axis = (1,0) 横向 / (0,1) 纵向，单位是 GI 图的纹素。
//输出 = 滤波后的 (rgb = 辐照度, a = 可信度)，两趟转一圈后直接落进"持久图里该写的那张"。
float4 SsgiBilateralBlur (float2 uv, float2 axis)
{
    float4 center = SAMPLE_TEXTURE2D_LOD(_SSGISourceTex, sampler_linear_clamp, uv, 0);

    float rawCenterDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
    if (rawCenterDepth < 0.00001)
        return center;//天空：自己就是 0，别把下面物体的 GI 抹上来（也会把邻居权重算错）

    int radius = max((int)_SSGIBlurRadius, 0);
    if (radius < 1)
        return center;

    float centerDepth = LinearEyeDepth(rawCenterDepth, _ZBufferParams);
    float3 centerNormal = SsgiSceneNormal(uv);

    //每侧最多 12 个抽头（半径大时跳着采：25 抽头已经够匀，再多几乎看不出差别）
    int tapsPerSide = min(radius, 12);
    float stepTexels = (float)radius / (float)tapsPerSide;
    float2 texelUV = _SSGITexelSize.xy * axis;

    float3 sum = center.rgb;
    float sumA = center.a;
    float sumW = 1.0;

    [loop]
    for (int i = 1; i <= tapsPerSide; i++)
    {
        float offset = i * stepTexels;
        float2 uvA = uv - texelUV * offset;
        float2 uvB = uv + texelUV * offset;
        float4 sampleA = SAMPLE_TEXTURE2D_LOD(_SSGISourceTex, sampler_linear_clamp, uvA, 0);
        float4 sampleB = SAMPLE_TEXTURE2D_LOD(_SSGISourceTex, sampler_linear_clamp, uvB, 0);
        float wA = SsgiBilateralWeight(uvA, centerDepth, centerNormal, offset, (float)radius);
        float wB = SsgiBilateralWeight(uvB, centerDepth, centerNormal, offset, (float)radius);

        sum += sampleA.rgb * wA + sampleB.rgb * wB;
        sumA += sampleA.a * wA + sampleB.a * wB;
        sumW += wA + wB;
    }
    return float4(sum / sumW, sumA / sumW);
}

//=========================== 四个 pass ===========================

//0.追踪：深度重建 → cosine 半球方向 → Hi-Z 步进 → 命中的着色、没命中的不贡献 → (辐照度, 可信度)
float4 TracePassFragment (Varyings input) : SV_Target
{
    float2 uv = input.screenUV;

    float rawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
    if (rawDepth < 0.00001)//天空/清屏色：这里没有接收面，a=0 让物体着色那边退回烘焙
        return float4(0, 0, 0, 0);

    //重建：世界坐标 + 世界法线（延迟：_GBuffer2；这一版只接延迟）
    float3 posWS = ScreenSpaceWorldPosFromDepth(uv, rawDepth);
    float3 normalWS = normalize(SAMPLE_TEXTURE2D_LOD(_GBuffer2, sampler_point_clamp, uv, 0).xyz * 2.0 - 1.0);

    //追踪在视空间做：起点 / 法线 / 方向都转过去（视空间 z 是负的，深度取 -z）
    float3 posVS = mul(UNITY_MATRIX_V, float4(posWS, 1.0)).xyz;
    float3 normalVS = mul((float3x3)UNITY_MATRIX_V, normalWS);

    int rayCount = max((int)_SSGIRayCount, 1);
    float2 pixelPos = uv * _CameraBufferSize.zw;//全分辨率像素坐标（随机数按像素分布）
    float3 gi = 0;
    float hitCount = 0;

    //R2 低差异序列常数（1/g, 1/g²，g = 塑料数）：**每根射线**沿它铺开（i 递增时这些点均匀铺满单位正方形）。
    //⚠️ 别用 `float2(IGN(seed), IGN(seed + 常数))` 凑两个随机数：**IGN 是一维噪声**，
    //   加常数只是"同一序列的另一个相位"（原来那个 `+ 13.7` 内层 dot 增量 ≈ 0.9994、被内层 frac 吃掉 ⇒ 两分量几乎相等）
    //   ⇒ Shirley 映射里 theta 恒为 π/4 ⇒ 半球方向**塌成一条弧**（GI patch 扁、只朝一个方向、不随相机转）。
    float2 r2 = float2(0.7548776662, 0.5698402909);

    //每像素 / 每帧的"基础相位"：优先用 STBN 图集（空间+时间都是蓝噪声），没配就退回程序化的 IGN 相位。
    //⚠️ 别在 STBN 值上再叠一个"每像素随机相位" —— 那会把它的空间结构搅成白噪声（白买这张图）。
    //图集寻址：512×512 = 8×8 个 64×64 切片；切片号沿时间走、xy 按屏幕像素取模（1 纹素 : 1 像素）。
    //⚠️ 全程在**纹素坐标**上算、最后才除以 512，并且自己 fmod 回 [0,512)：这样 UV 恒落在 [0,1) 内
    //   ⇒ 用工程里现成的 `sampler_point_clamp` 就够。
    //   （本工程只声明了 sampler_linear_clamp / sampler_point_clamp 两个采样器 —— 用 `sampler_point_repeat`
    //    会**编译不过** ⇒ 整个 SSGI shader 失效 ⇒ 连四趟绘制都不会发出去、画面上一丝 GI 都没有）
    float2 tile = float2(fmod(_SSGISliceIndex, 8.0), floor(_SSGISliceIndex / 8.0));
    float2 texelA = fmod(tile * 64.0 + fmod(pixelPos, 64.0), 512.0);
    //第二个分量：错开半张图（256 纹素）⇒ 落到别的切片、和第一个去相关（半球采样要的确实是二维点）
    float2 texelB = fmod(texelA + 256.0, 512.0);
    float2 stbn = float2(
        SAMPLE_TEXTURE2D_LOD(_SSGIBlueNoise, sampler_point_clamp, (texelA + 0.5) / 512.0, 0).r,
        SAMPLE_TEXTURE2D_LOD(_SSGIBlueNoise, sampler_point_clamp, (texelB + 0.5) / 512.0, 0).r);
    float ignPhase = InterleavedGradientNoise(pixelPos + _SSGIRandomOffset.xy * 64.0, 0);
    float2 basePhase = lerp(ignPhase.xx, stbn, saturate(_SSGIBlueNoiseEnabled));

    [loop]
    for (int i = 0; i < rayCount; i++)
    {
        //i=0 也避开"两分量相等"那个退化点（u = (0.5,0.5) ⇒ u2 = 0）
        float2 u = frac(basePhase + r2 * (float)(i + 1));
        float3 dirWS = SsgiCosineHemisphere(u, normalWS);
        float3 dirVS = normalize(mul((float3x3)UNITY_MATRIX_V, dirWS));

        float2 hitUV;
        float hitZ;
        if (SsgiTraceRayWithHiZ(posVS, dirVS, normalVS, hitUV, hitZ))
        {
            //背面剔除：射线从命中面的**背面**穿过去 ⇒ 我们采到的只是它正面那点着色 ⇒ 假命中（漏光的直接来源）。
            //整根作废（不加辐照度、也不加命中率）⇒ 该处可信度 a 掉下去 ⇒ 物体着色 `lerp(烘焙, GI, a)` 退回烘焙。
            //⚠️ 原来是"乘一个软权重"（`1 - saturate(dot)`）：那等于把这根按 0 贡献算进平均 ⇒ 白白把 GI 压暗，
            //   而且用的是着色法线（法线图一花就误判）⇒ 会闪。现在是硬剔除 + 几何面法线。
            //⚠️ 判在 SsgiShadeHit **之前**：假命中的整套着色（GBuffer1/2/5 + 级联阴影 + 点光阴影）直接省掉。
            SsgiHit hitData = SsgiLoadHit(hitUV, dirVS);
            if (!hitData.frontFacing)
                continue;

            gi += SsgiCompress(SsgiShadeHit(hitData, hitUV));
            hitCount += 1.0;
        }
        //（没有 else：没追到 / 出屏的路**什么都不贡献**，不塞 SH）
        //原来这里是"塞一个 SH 探针的整半球值"，那是**无条件**的（被墙挡住的射线也照样给一个未遮挡的亮值）
        //⇒ 漏光的直接来源。现在让可信度 a 掉下去，消费端 `lerp(烘焙, GI, a)` 自然退回烘焙
        //（烘焙里本来就有环境光 ⇒ 不会变暗，也不会凭空加亮）。
    }

    //cosine 加权采样 ⇒ 平均就是半球积分（辐照度，不用再乘 π）。
    //⚠️ 除的是**命中的根数**不是总根数：没命中的那些由 a（可信度）表达"这块不确定"，
    //   不能在这里再除一次，否则会"既变暗、又降低权重"（双重打折）。
    gi = SsgiUncompress(gi / max(hitCount, 1.0));

    float confidence = hitCount / rayCount * SsgiScreenFade(uv);
    if (_SSGIDebugIndirect > 0.5)//调试：让物体着色整块用 GI（不看烘焙），方便单独看间接光
        confidence = 1.0;

    return float4(max(gi, 0.0), confidence);
}

//1.时间累积：本帧追踪（_SSGISourceTex）+ 历史（_SSGITex）→ 目标
//（没有运动矢量：历史位置靠"深度 + 上一帧 VP"重投影，和 TAA 同一套式子 ⇒ 相机移动没问题，动的物体会拖）
float4 TemporalPassFragment (Varyings input) : SV_Target
{
    float2 uv = input.screenUV;
    float4 current = SAMPLE_TEXTURE2D_LOD(_SSGISourceTex, sampler_linear_clamp, uv, 0);

    //重置帧（首帧 / 刚重建 / 换相机 / 瞬移 / 切场景）：这帧只写当前帧，历史从下一帧开始混
    //（标记在 _SSGIRandomOffset.z，C# 每帧上传）
    if (_SSGIRandomOffset.z > 0.5)
        return current;

    float rawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
    if (rawDepth < 0.00001)
        return float4(0, 0, 0, 0);//天空：a=0 ⇒ 物体着色那边退回烘焙

    //重投影：本像素的世界坐标 →（未抖动的）上一帧 VP → 上一帧屏幕 uv
    float3 positionWS = ScreenSpaceWorldPosFromDepth(uv, rawDepth);
    float4 prevClip = mul(_SSGIPrevViewProj, float4(positionWS, 1.0));
    float2 historyUV = prevClip.xy / prevClip.w * 0.5 + 0.5;
    #if UNITY_UV_STARTS_AT_TOP
        historyUV.y = 1.0 - historyUV.y;//和 ScreenSpaceWorldPosFromDepth 里那次 y 取反对应
    #endif

    //把**本帧抖动**加回去：本帧这个像素（按抖过的矩阵画）采到的是"未抖动位置 p − j"那个表面点，
    //而 `_SSGIPrevViewProj` 是**未抖动**的 ⇒ 投回来自然也是 p − j；再加上 j 才正好落在**本像素自己**身上。
    //⚠️ 和 `TemporalAntiAliasing.shader` 里那一行完全对应（TAA 早就这么做了、我们漏了）：
    //   不加的话，静止不动时历史也每帧被采在偏 ~0.25 个（半分辨率）纹素的位置
    //   ⇒ 每帧往结果里掺一层高频抖动，顺带把历史跟邻居混着用（等于稀释掉累积）。
    historyUV += _SSGIJitter.xy;

    float4 history = SAMPLE_TEXTURE2D_LOD(_SSGITex, sampler_linear_clamp, historyUV, 0);

    //压缩域（和追踪那趟同一个压缩）里做 AABB / 裁剪 / 混合：亮部不发散 ⇒ 鬼影/拖影明显少，输出前再还原
    float3 currentC = SsgiCompress(current.rgb);
    float3 historyC = SsgiCompress(history.rgb);

    //3×3 邻域 AABB：历史跟当前这一带差太多（换了物体 / 被遮住 / 鬼影）就把它拉回盒子里
    float3 boxMin, boxMax;
    boxMax = boxMin = SsgiRGBToYCoCg(currentC);
    [unroll]
    for (int k = 0; k < 9; k++)
    {
        float3 sampled = SAMPLE_TEXTURE2D_LOD(_SSGISourceTex, sampler_linear_clamp,
            uv + _SSGITexelSize.xy * SsgiOffsets3x3[k], 0).rgb;
        float3 c = SsgiRGBToYCoCg(SsgiCompress(sampled));
        boxMin = min(boxMin, c);
        boxMax = max(boxMax, c);
    }
    //盒子按 temporalScale 放大：越大越信历史（更稳，也更容易鬼影）
    float3 boxCenter = (boxMin + boxMax) * 0.5;
    float3 boxExtent = (boxMax - boxMin) * 0.5 * max(_SSGITemporalScale, 1.0);
    historyC = SsgiYCoCgToRGB(SsgiClipHistory(SsgiRGBToYCoCg(historyC),
        boxCenter - boxExtent, boxCenter + boxExtent));

    //当前帧权重 = 1 - 历史权重 + "重投影位移 × 放大系数"（位移越大越信当前帧）。
    //⚠️ 这个系数是从 TAA 搬来的：**TAA 那边位移 = 物体运动（它有 MV）**，才成立。
    //   我们**没有 MV**，这里的位移其实是"**相机移动**造成的重投影位移"，而深度重投影在相机移动时是准的
    //   ⇒ 系数给大了就会"相机一动、历史权重直接归零"（每帧只剩那几条射线 ⇒ 大片噪点）。
    //   由 `_SSGIMotionBlendScale` 控制（0 = 完全不惩罚，移动时照样累积）。
    float blend = saturate(1.0 - _SSGITemporalWeight + length(uv - historyUV) * _SSGIMotionBlendScale);
    //历史不可用：投出屏幕，或者那一格本来就没数据（上一帧是天空/没追到 ⇒ 可信度 0）
    if (historyUV.x < 0.0 || historyUV.x > 1.0 || historyUV.y < 0.0 || historyUV.y > 1.0 || history.a < 0.001)
        blend = 1.0;

    return float4(SsgiUncompress(lerp(historyC, currentC, blend)), lerp(history.a, current.a, blend));
}

//2.横向双边：_SSGISourceTex → 目标
float4 BlurHorizontalPassFragment (Varyings input) : SV_Target
{
    return SsgiBilateralBlur(input.screenUV, float2(1.0, 0.0));
}

//3.纵向双边：_SSGISourceTex → 目标（本帧最后落到"持久图里该写的那张"）
float4 BlurVerticalPassFragment (Varyings input) : SV_Target
{
    return SsgiBilateralBlur(input.screenUV, float2(0.0, 1.0));
}

#endif
