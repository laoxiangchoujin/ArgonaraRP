#ifndef CUSTOM_SSR_INCLUDED
#define CUSTOM_SSR_INCLUDED

//屏幕空间反射（SSR）的 shader 代码。
//由 ScreenSpaceReflection.shader 的 HLSLINCLUDE include；**各个 pass 的 fragment 函数体都写在这里**，
//shader 里只留"Pass 名 + #pragma vertex/#pragma fragment"（和 ScreenSpacePCSS.shader 的分工一致）。
//
//**本轮是从 URP 那边的 sh_SSR.shader + ssr.hlsl 整体搬过来的**，三处 API 替换：
//  1) _ScaledScreenParams.xy        →  _CameraBufferSize.zw（本项目没有 _ScaledScreenParams；注意 _CameraBufferSize = (1/w, 1/h, w, h)，
//                                       所以要"像素宽高"的地方用 .zw、"1/像素"的地方用 .xy）
//  2) TransformWViewToHClip / TransformWorldToViewDir  →  原样可用（Common.hlsl 已经 include 了 core 的 SpaceTransforms.hlsl）
//  3) 反射源颜色 _CameraOpaqueTexture →  _CameraColorTexture（本项目折射用的那张拷贝；现在还带 mip 链，以后做 roughness→mip 直接用）
//顺手修的几处小东西：
//  ① Swap() 换手写（core 的 Common.hlsl 不保证提供 Swap）
//  ② 深度采样器用 sampler_point_clamp（深度不该被线性过滤）
//  ③ 法线分两种用途，别混：**反射方向**用着色法线（ScreenSpaceSceneNormal：延迟 _GBuffer2、前向 _CameraNormalsTexture），
//     **背面剔除**用几何面法线（ScreenSpaceGeometricNormal 从深度重构，见 IsHitFrontFacing）
//
//**还没搬的（故意留着 = 需要做大改的）**：见文件末尾 TODO。

//=========================================================
//====== SSR 的两张图 & 纹素尺寸 ======
//=========================================================
//反射图自己的纹素尺寸：xy = 1/宽、1/高（zw = 宽、高），由 C# 按这张半分辨率图的实际尺寸上传。
//SSR **只有这一套**尺寸（追踪和两趟模糊都在同一张半分辨率图上），不像屏幕空间阴影要两套
float4 _SSRTexelSize;

//反射图：追踪那一趟的输出，也是两趟模糊之间的主图。由 C# 每帧 SetGlobalTexture 绑定。
//（TEXTURE2D(_SSRTex) 的声明已经挪到 GI.hlsl —— 那边也要用它做高光融合，两处都声明会重复定义）
//横向模糊的倒手图：横趟读 _SSRTex 写它，竖趟读它写回 _SSRTex
TEXTURE2D(_SSRTex_TempBlur);

//=========================================================
//====== 模糊（±2 五点二项式 + 消萤火虫）======
//=========================================================
//基础权重 (1,4,6,4,1)/16：便宜、形状接近高斯。
//在此之上再乘一个"按亮度反向"的权重 w = 1/(Luminance+1)（= 卡特莱克 bloom 里的 fade fireflies 那招）：
//亮度越高的抽头权重越小 ⇒ 孤立的高亮命中点（firefly，比如单点命中太阳高光）被邻居平均掉，是个不看阈值的"软 clamp"。
//⚠️ 加了这层权重后"权重和"不再是 1 ⇒ 返回前要除以权重和（关掉开关时权重和恰好=1，行为与改动前一致）。
//为什么不用屏幕空间阴影那种双边滤波：反射图里的深度/法线跳变**是内容**（镜子里本来就该看到
//不同深度/朝向的东西），双边会把反射细节吃掉；而且双边每抽头要读深度 + 法线 + 重建世界坐标。

//这个采样器/纹理用的亮度：和 PostFXStackPasses.hlsl 里 bloom 那招同一个式子
//（不直接用 core 的 Luminance()，避免和别处已 include 的定义撞名）
float SsrLuminance (float3 color) { return dot(color, float3(0.2126, 0.7152, 0.0722)); }

//是否消萤火虫（1=开、0=关）。由 C# 从 SSRSettings 上传；关掉就是纯二项式模糊
float _SSRFireflySuppression;

//压亮度的强度 k：权重 w = 1/(Luminance*k + 1)。
//k = 0 ⇒ w = 1（完全不压，等价于把上面开关关掉）；k = 1 ⇒ 卡特莱克原式；k 越大压得越狠
float _SSRFireflyStrength;

//横向：_SSRTex → _SSRTex_TempBlur
float4 BlurHorizontalPassFragment (Varyings input) : SV_Target
{
    float2 uv = input.screenUV;
    float texelX = _SSRTexelSize.x;

    //1/16, 4/16, 6/16, 4/16, 1/16
    static const float kernel[5] = { 0.0625, 0.25, 0.375, 0.25, 0.0625 };

    float4 sum = 0.0;
    float weightSum = 0.0;
    [unroll]
    for (int i = -2; i <= 2; i++)
    {
        float4 c = SAMPLE_TEXTURE2D_LOD(_SSRTex, sampler_linear_clamp, uv + float2(i * texelX, 0.0), 0);
        float w = kernel[i + 2] * lerp(1.0, 1.0 / (SsrLuminance(c.rgb) * _SSRFireflyStrength + 1.0), _SSRFireflySuppression);
        sum += w * c;
        weightSum += w;
    }
    return sum / max(weightSum, 1e-5);
}

//纵向：_SSRTex_TempBlur → _SSRTex（和横向完全对称，只是取 y 方向的邻居；两趟转一圈结果仍在主图上）
float4 BlurVerticalPassFragment (Varyings input) : SV_Target
{
    float2 uv = input.screenUV;
    float texelY = _SSRTexelSize.y;

    static const float kernel[5] = { 0.0625, 0.25, 0.375, 0.25, 0.0625 };

    float4 sum = 0.0;
    float weightSum = 0.0;
    [unroll]
    for (int i = -2; i <= 2; i++)
    {
        float4 c = SAMPLE_TEXTURE2D_LOD(_SSRTex_TempBlur, sampler_linear_clamp, uv + float2(0.0, i * texelY), 0);
        float w = kernel[i + 2] * lerp(1.0, 1.0 / (SsrLuminance(c.rgb) * _SSRFireflyStrength + 1.0), _SSRFireflySuppression);
        sum += w * c;
        weightSum += w;
    }
    return sum / max(weightSum, 1e-5);
}

//=========================================================
//====== 追踪用到的调参（全屏 pass 里当全局 uniform，C# 从 SSRSettings 上传）======
//=========================================================
//（原版这些是水面材质的 UnityPerMaterial；搬到全屏 pass 后只能走全局。C# 那边还没接，先声明好）
float _SSRTotalRayLength;       //射线总长（视空间米）：没碰到东西就在这个长度内一直步进
float _SSRPixelStride;          //每步跨多少屏幕像素：越大越快、越容易漏交
int _SSRStepCountLimit;         //步数上限：防止 stride 太小时步数爆炸
float _SSRNearStepBoldenRange;  //近处放宽步长的生效距离（米）：越近步长越宽（最多×2）
float _SSRPixelThickness;       //深度厚度（视空间米）：判交用的"物体有多厚"
float _SSRBackRayFadeWidth;     //反射方向朝相机时的淡出宽度
float _SSRScreenEdgeFadeStart;  //屏幕边缘淡出的起点（屏幕中心=0、边缘=1）
float _SSRMarchFadeStrength;    //命中点越靠射线末端越淡的强度（0=不衰减）

//粗糙度→mip：反射色按"接收面粗糙度"取颜色快照的 mip 级（越粗糙越糊 ⇒ 命中点抖动/闪点被平均掉）。
//lod = scale * roughness + bias，lod 的有效上限 = 颜色快照的 mip 级数 - 1（由 CameraBufferSettings.copyColorMipCount 决定）
float _SSRRoughnessMipScale;
float _SSRRoughnessMipBias;

//命中点/接收面的**着色法线**（含法线贴图）：延迟读 GBuffer2，前向读 DepthNormals prepass 的法线图。
//编码统一是 "normal * 0.5 + 0.5"，所以解码一样（和 ScreenSpacePCSS.shader 里那份一致）
TEXTURE2D(_CameraNormalsTexture);
float3 ScreenSpaceSceneNormal (float2 uv)
{
    float3 encoded = (_UseDeferredRenderer > 0)
        ? SAMPLE_TEXTURE2D(_GBuffer2, sampler_point_clamp, uv).xyz
        : SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_point_clamp, uv).xyz;
    return normalize(encoded * 2.0 - 1.0);
}

//=========================================================
//====== 抖动：4×4 有序抖动表 ======
//=========================================================
//（Thetus 文章里那张，就是标准 4×4 Bayer 矩阵 ÷16，值 ×16 后为
//  0 8 2 10 / 12 4 14 6 / 3 11 1 9 / 15 7 13 5）
//用固定图案替代随机噪声：同一像素扰动固定、相邻像素按规律错开，静态观感是"规则网点"而非"雪花"
static const float jitterDither[16] = {
    0.0,   0.5,   0.125, 0.625,
    0.75,  0.25,  0.875, 0.375,
    0.187, 0.687, 0.0625,0.562,
    0.937, 0.437, 0.812, 0.312
};
float JitterDither(float2 pixelPos)
{
    float2 p = fmod(floor(pixelPos), 4.0);//按 4x4 平铺，先取模保证大坐标下的精度
    return jitterDither[(int)p.x * 4 + (int)p.y];
}

//=========================================================
//====== 追踪（intersect / traceRay / alphaCalc）======
//=========================================================

//视空间点 → 屏幕 UV(0~1)
//投影翻转交给 _ProjectionParams.x：渲染到 RT 时它自动为 -1、渲染到 backbuffer 时为 +1
//（URP: ScriptableRenderer.cs 里 projectionParams.x = isTargetFlipped ? -1 : 1）
//比手写 UNITY_UV_STARTS_AT_TOP 可靠 —— 平台常量区分不出"是否渲染到 RT"这两种情况
float2 ViewToScreenUV(float3 posVS)
{
    float4 posCS = TransformWViewToHClip(posVS);
    return float2(posCS.x, posCS.y * _ProjectionParams.x) / posCS.w * 0.5 + 0.5;
}

//一次步进的"两端深度"判交：让这一步的终点 > 其他物体正面深度，同时起点 < 正面深度 + thickness
//（没有背面 pass，就用 正面深度 + thickness 表示"这个物体的背面"）
//名字：原版叫 intersect，搬过来改成了 DepthIntersect —— DXR 里 intersect 是内建函数名，容易和编译器/内建列表撞
bool intersect(float rayStapA, float rayStepB, float2 screenPixel)
{
    //视空间深度（米）恒为正；出现非正值说明射线已越过相机平面，直接判为未命中
    if (rayStapA <= 0 || rayStepB <= 0)
        return false;

    //一次步进里不确定哪个更深，先排个序，假定 rayStepB 更大（更深）
    if (rayStapA > rayStepB)
    {
        Swap(rayStapA,rayStepB);
    }

    float decodedDepth = LinearEyeDepth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, screenPixel), _ZBufferParams);
    return rayStepB > decodedDepth && rayStapA < decodedDepth + _SSRPixelThickness;
}

//从 startVS 沿 reflectDirVS 在屏幕空间步进找交点。
//命中则回去 hitPixel / marchPercent（命中点在整条射线上的进度 0~1）/ hitZ（命中点视空间深度，米）
bool traceRay(float3 startVS, float3 reflectDirVS, out float2 hitPixel, out float marchPercent, out float hitZ)
{
    //要在屏幕空间计算，先把起点和终点的屏幕空间UV算出来，then用一个interpolation表示它俩之间的插值
    float2 startSS = ViewToScreenUV(startVS);

    float3 endVS = startVS + reflectDirVS * _SSRTotalRayLength;//射线总长（视空间米）
    float2 endSS = ViewToScreenUV(endVS);

    //"像素宽高"（_CameraBufferSize = (1/w, 1/h, w, h)，所以这里取 .zw）
    float2 bufferSizeXY = _CameraBufferSize.zw;
    if (length(startSS - endSS) < min(1 / bufferSizeXY.x, 1 / bufferSizeXY.y))//若两点距离甚至小于1像素，就让终点额外走 xy 各一像素
        endSS += 1 / bufferSizeXY;

    //这里要存 1/z：屏幕空间步进做完透视除法后，屏幕上走的距离并不直接对应 z 的变化，反而 1/z 是线性对应的
    //（透视投影下，沿屏幕上的直线插值时 1/Z（准确说 1/W）是线性变化的量）
    float2 deltaPixels = (endSS - startSS) * bufferSizeXY;
    //_SSRNearStepBoldenRange：近处放宽步长的生效距离（米）。越近步长越宽（最多 ×2），超过它按基准步长走
    float sampleScalar = 1.0 - min(1.0, -startVS.z / max(_SSRNearStepBoldenRange, 0.001));

    //每步在屏幕上跨多少像素（目标值）：间隔越大 ⇒ 步数越少 ⇒ 越快、越容易漏交
    //近处放宽（×1~2）、远处收紧，避免同样的世界距离在 near 处占用过多采样
    float pixelsPerStep = max(_SSRPixelStride * (1.0 + sampleScalar), 0.0001);
    //屏幕跨度取较长的那根轴，与原来 min(1/|dx|,1/|dy|) 的口径一致
    float screenSpan = max(abs(deltaPixels.x), abs(deltaPixels.y));
    //不封顶时的步数 ≈ 屏幕跨度 / 每步像素；向上取整保证整条射线被走满（实际每步略小于 pixelsPerStep）
    //再由最大步数封顶：上限生效时每步会被自动拉长，射线就走不满 _SSRTotalRayLength
    int stepCount = max(min(_SSRStepCountLimit, (int)ceil(screenSpan / pixelsPerStep)), 1);
    float invStepCount = 1.0 / (float)stepCount;

    hitZ = 0;	hitPixel = 0;	marchPercent = 1;//out 参数不会自动初始化，先把未命中时可能被读到的值定好

    float2 currentSS = startSS;
    float current1bz = 1.0 / -startVS.z;//为啥不管负号

    //把整条射线按步数等分：1/z 沿屏幕上的直线是线性变化的，所以直接均分步数即可得到每步的 1/z 增量
    float2 deltaSS = (endSS - startSS) * invStepCount;
    float delta1bz = (1.0 / -endVS.z - 1.0 / -startVS.z) * invStepCount;
    //步进之前，给UV和深度都加个一次性的jitter（按像素坐标查 4x4 有序抖动表，0..1）
    float jitter = JitterDither(currentSS * bufferSizeXY);
    currentSS += jitter * deltaSS;
    current1bz += jitter * delta1bz;

    //起点自交保护：把首步的 prev 沿射线方向再推 0.1 步，缓解数值误差导致的"起点与自身所在表面判交"
    //（1/z 沿射线线性变化，所以直接在 1/z 上加 0.1 步的增量等价于把采样点沿射线推进 0.1 步）
    float prev1bz = current1bz + 0.1 * delta1bz;

    bool intersected = false;

    [loop]
    for (int i = 0; i < stepCount && !intersected; i++)
    {
        float2 screenCoord = currentSS + 0.5 * deltaSS;
        currentSS += deltaSS;
        float currentZVSPrev = 1 / prev1bz;
        current1bz += delta1bz;
        float currentZVS = 1 / current1bz;
        prev1bz = current1bz;//首步之后，prev 就是真实的上一个采样点

        if (screenCoord.x < 0 || screenCoord.x > 1 || screenCoord.y < 0 || screenCoord.y > 1)
            return false;
        if (currentZVS < 0)
            return false;

        if (intersect(currentZVSPrev, currentZVS, currentSS - 0.5 * deltaSS))
        {
            hitPixel = currentSS - 0.5 * deltaSS;
            marchPercent = (i + 0.5) * invStepCount;//采样点落在这一步的中间，进度取 (i+0.5)/stepCount
            intersected = true;
            break;
        }
    }

    //二分查找：在前步进点、后步进点之间逐次取中点，选前后其中一部分（这里把 left 当前边、right 当后边）
    #if 1
        if (intersected)
        {
            float2 leftSS = currentSS - deltaSS;//往前回退一步
            float left1bz = current1bz - delta1bz;
            float2 rightSS = currentSS;
            float right1bz = current1bz;

            //两次步进中间差多少，不是简单相加除二，而是看单次步进距离被投射到 z 轴有多长，再除二
            [loop]
            for (int j = 0; j < 6; j++)
            {
                float2 deltaSSInBinary = rightSS - leftSS;
                float delta1bzInBinary = right1bz - left1bz;

                //优先尝试在左边找（在SS步进）
                float2 midSS = leftSS + 0.5 * deltaSSInBinary;
                float mid1bz = left1bz + 0.5 * delta1bzInBinary;
                float midZ = 1.0 / mid1bz;

                if (intersect(1 / left1bz, midZ, midSS))//在左半边找到了
                {
                    rightSS = midSS;    //left 不变，right 变成 mid
                    right1bz = mid1bz;
                }
                else                    //左边没找到，在右边找到
                {
                    leftSS = midSS;
                    left1bz = mid1bz;
                }
            }
            hitPixel = rightSS;//二分结束，用 right 当最终结果
            hitZ = 1 / right1bz;
        }
    #else
    hitZ = 1/current1bz;
    #endif

    return intersected;
}

//命中的"可信度"（四项淡出），返回值当 alpha 用：0 = 别用这次命中，1 = 完全相信
float alphaCalc(float3 rayDirection, float2 hitPixel, float marchPercent, float hitZ)
{
    float res = 1;

    //反射方向朝相机的淡出：viewZ≤0（朝远处）全亮，viewZ 越正（越朝相机飞来）越淡，达到 _SSRBackRayFadeWidth 完全消失
    //镜子里应该看到相机背后/贴近相机的东西，而那块画面根本不在屏幕上，SSR 无论如何都取不到，只会取到错误的像素，所以拦掉
    res *= saturate(1.0 - rayDirection.z / max(_SSRBackRayFadeWidth, 0.001));

    //屏幕边缘淡出：把命中点转到 NDC，用"屏幕中心=0、屏幕边缘=1"的归一化半径衡量，超过 _SSRScreenEdgeFadeStart 开始淡出
    float2 screenPCurrent = 2 * (hitPixel - 0.5);//坐标转到-1，1
    float2 screenEdgeFade01 = saturate((abs(screenPCurrent) - _SSRScreenEdgeFadeStart) / max(1.0 - _SSRScreenEdgeFadeStart, 0.001));
    res *= 1 - max(screenEdgeFade01.x, screenEdgeFade01.y);

    //命中点越靠射线末端越淡，强度由 _SSRMarchFadeStrength 控制（0=不衰减）
    res *= 1 - marchPercent * _SSRMarchFadeStrength;

    //远处淡出：hitZ / far（_ProjectionParams.w = 1/far）
    res *= saturate(1.0 - hitZ * _ProjectionParams.w);

    return res;
}

//背面剔除：射线若从物体背面穿过该表面，我们只能取到它正面的颜色，属于假命中。
//用的是**几何面法线**（从深度重构、不含法线图扰动）：这是"面的朝向/可见性"判据，和光照一样该用几何法线——
//若用着色法线，法线贴图很花的地方会把"正面"误判成"背面"⇒ 该有反射的位置出现黑点/闪烁。
//只在命中点算一次（1次重建 + 4次深度采样），不塞进会被调用几十次的 intersect 里。
bool IsHitFrontFacing(float3 reflectDirVS, float2 hitPixel)
{
    float rawHitDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, hitPixel);
    float3 shadingNormal = ScreenSpaceSceneNormal(hitPixel);
    //天空/无效像素：法线图未生成时采样为0（深度也都是0）⇒ 没有面可判，不剔除
    if (rawHitDepth < 0.00001 || dot(shadingNormal, shadingNormal) < 0.001)
        return true;

    //命中点世界坐标 + 视深度 → 几何面法线（着色法线只当"统一朝向"的参考，见 Fragment.hlsl 里该函数头）
    float3 hitPosWS = ScreenSpaceWorldPosFromDepth(hitPixel, rawHitDepth);
    float hitViewDepth = -TransformWorldToView(hitPosWS).z;
    float3 hitNormalWS = ScreenSpaceGeometricNormal(hitPosWS, hitViewDepth, shadingNormal, hitPixel);
    //<0 = 从正面进入
    return dot(reflectDirVS, normalize(TransformWorldToViewDir(hitNormalWS))) < 0.0;
}

//取命中点的反射颜色。原版是 _CameraOpaqueTexture；本项目用 _CameraColorTexture（折射那张拷贝）。
//lod 由调用方给（粗糙度→mip）：越粗糙采越糊的一级，把命中点抖动/闪点平均掉。
//采样器用"按纹理命名"的那个（见 Fragment.hlsl）：颜色快照带 mip 时它是 Trilinear，
//lod 落在两级之间时会插值 ⇒ 不会出现"取整到最近一级"造成的台阶/跨级跳变
float3 SampleReflectionColor(float2 hitPixel, float lod)
{
    return SAMPLE_TEXTURE2D_LOD(_CameraColorTexture, sampler_CameraColorTexture, hitPixel, lod).rgb;
}

//=========================================================
//====== 追踪那一趟的 fragment（shader 里的 pass 0）======
//=========================================================
//放在文件末尾只是因为要用到上面那些函数（HLSL 要求先定义后使用）；
//shader 里的 Pass 顺序才是真正的调用顺序：0 = Trace、1/2 = 两趟blur。
//
//和原版水面 pass 的区别：原版的起点/反射方向来自物体自己的 posWS/normalWS；
//这里是全屏 pass，所以拿**深度重建的世界坐标 + GBuffer的法线**来造这两个输入
//（重建那套照抄 CameraRendererPasses.hlsl 的 DeferredLightPassFragment，口径完全一致）。
//
//输出：rgb = 命中的反射颜色（未预乘），a = 这次命中可信度（alphaCalc）。
//未命中 / 被背面剔除 / 天空像素 → 输出0，交给接收面用它自己的环境反射 fallback 顶上。
//⚠️ 这一趟是**半分辨率**：uv 采深度/法线时相当于是那个2×2 block 的代表点，
//   所以反射边缘会有不到1个屏幕像素的偏移，靠后面两趟blur抹平。
float4 TracePassFragment (Varyings input) : SV_Target
{
    float2 uv = input.screenUV;

    //1.深度 → 世界坐标（全屏 pass 的公共工具，见 Fragment.hlsl）
    float rawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
    if (rawDepth < 0.00001)//深度几乎是0 = 天空/清屏色：这里没有接收面，不产生反射
    {
        return 0.0;
    }
    float3 posWS = ScreenSpaceWorldPosFromDepth(uv, rawDepth);

    //2.接收面的法线 + 反射方向（都要视空间的，步进在视空间/屏幕空间里做）
    float3 normalWS = ScreenSpaceSceneNormal(uv);
    float3 startVS = TransformWorldToView(posWS);
    float3 normalVS = normalize(TransformWorldToViewDir(normalWS));
    float3 viewDirVS = normalize(startVS);//相机(0,0,0) → 表面点
    float3 reflectDirVS = normalize(reflect(viewDirVS, normalVS));

    //3.沿反射方向在屏幕空间步进找交点
    float2 hitPixel;
    float marchPercent;
    float hitZ;
    if (!traceRay(startVS, reflectDirVS, hitPixel, marchPercent, hitZ))
    {
        return 0.0;
    }

    //4.背面剔除：命中点若是"背面朝射线"，我们只能取到它正面的颜色，属于假命中
    if (!IsHitFrontFacing(reflectDirVS, hitPixel))
    {
        return 0.0;
    }

    //5.取色 + 算这次命中的可信度（四项淡出）
    //反射色按"接收面粗糙度"取 mip：越粗糙采越糊的一级（命中点抖动、HDR 高光闪点都被平均掉）。
    //lod = scale * roughness + bias；上限由颜色快照的 mip 级数决定（超了硬件自己夹住），bias 为负就是整体更清
    //（粗糙度只有延迟有 —— 延迟那边 _GBuffer3 就是接收面的 roughness；前向没有 GBuffer、那个名字也没绑定，
    //  所以前向的粗糙度按 0 算 = lod 只用 bias，先让反射保持清晰）
    float receiverRoughness = (_UseDeferredRenderer > 0)
        ? SAMPLE_TEXTURE2D(_GBuffer3, sampler_linear_clamp, uv).x
        : 0.0;
    float lod = max(_SSRRoughnessMipScale * receiverRoughness + _SSRRoughnessMipBias, 0.0);
    float3 reflection = SampleReflectionColor(hitPixel, lod);
    float alpha = alphaCalc(reflectDirVS, hitPixel, marchPercent, hitZ);
    return float4(reflection, alpha);
}

//=========================================================
//====== TODO ======
//=========================================================
//接收面/水面的合成不在这个 shader 里：按既定架构，透明物（水面等）自己在自己的着色里采 _SSRTex 做 Fresnel/粗糙度合成。
//不透明物体也不需要"合成pass"：它们在**自己的物体pass**（前向Lit / 延迟GBuffer与地形）里就调
//  SampleEnvironment(surface, brdf, screenUV) 把"环境反射 + 上一帧SSR"按可信度a混好、写进最终颜色/GT4。

#endif
