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
int _BinarySearchCountLimit;
float _SSRNearStepBoldenRange;  //近处放宽步长的生效距离（米）：越近步长越宽（最多×2）
float _SSRPixelThickness;       //深度厚度（视空间米）：判交用的"物体有多厚"
float _SSRRayOffset;            //起点沿法线抬起的距离（视空间米）：治自交。0.01 量级（太大 ⇒ "钳制范围"，太小 ⇒ 自反射）
float _SSRBackRayFadeWidth;     //反射方向朝相机时的淡出宽度
float _SSREdgeFadeScale;        //暗角式屏幕边缘淡出：离屏幕中心的距离倍率（原始值 1.8）
float _SSREdgeFadeAttenuation;  //暗角式屏幕边缘淡出：距离的整形幂（原始值 1）
float _SSRMarchFadeStrength;    //命中点越靠射线末端越淡的强度（0=不衰减）

//粗糙度→mip：反射色按"接收面粗糙度"取颜色快照的 mip 级（越粗糙越糊 ⇒ 命中点抖动/闪点被平均掉）。
//lod = scale * roughness + bias，lod 的有效上限 = 颜色快照的 mip 级数 - 1（由 CameraBufferSettings.copyColorMipCount 决定）
float _SSRRoughnessMipScale;
float _SSRRoughnessMipBias;

//=========================================================
//====== Hi-Z（分层深度图）：追踪用它决定步长 ======
//=========================================================
//主图（带 mip 链，每级一个纹素 = 该块里"离相机最近"的深度）+ 可用级数上限，
//都由 HierarchicalZ 每帧生成并上传（生成流程见那边；这里只负责用）。
TEXTURE2D(_HiZTex);
//可用的最高 mip 级：追踪里 clamp 用（再高的级别没写过数据）
int _MaxHiZMipLevel;
//本帧 HiZ 到底可不可用（1/0）。关掉时 C# 会把 _HiZTex 绑成 1×1 黑图（深度 0 = 无穷远），
//那种情况下照着 Hi-Z 走会"永远不命中" ⇒ 必须靠它退回下面的线性步进 traceRay。
float _HiZEnabled;
//SSR **自己**要不要用 Hi-Z 追踪（SSRSettings.useHiZ，由 ScreenSpaceReflection 每帧上传）：
//关掉就固定走线性步进 —— 拿来对比两种追踪/排查问题。⚠️ 和"资源有没有"（_HiZEnabled）是两件事。
float _SSRUseHiZ;

//调试开关（**默认关**）：打开后追踪那趟不输出反射，改成按"射线为什么结束"染色 ——
//  白=命中 / 红=走出屏幕 / 绿=越过相机平面 / 蓝=步数用光 / 黑=起点就没有面（天空）
//  走到射线终点的三种细分：黄=没被截断且几乎走完整条（长度内真没东西） / 橙=没被截断但很早就结束（一步跨过终点）
//                          品红=这条射线被近平面截断过（本来就短）
//（排查"某块区域为什么没反射"用的；用完注释回去即可）
//#define SSR_TRACE_DEBUG

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
            for (int j = 0; j < _BinarySearchCountLimit; j++)
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

///Hi-Z 版追踪：入参/出参口径和 traceRay 完全一致（startVS 起点、reflectDirVS 方向；
///命中给 hitPixel / marchPercent / hitZ）。
///**但步进方式完全不同**：按 mip 级升降步长 ——
///  这一步的远端点越过了该级存的"最近深度" ⇒ 可疑：mip0 时（落在 thickness 内）算命中，
///  否则退回一步、mip-1 换更细的级；没越过 ⇒ 这一整块都没东西 ⇒ mip+1、步长翻倍（最多 _MaxHiZMipLevel）。
///⇒ 所以它是**另一套循环**，和"等步长 + 末尾二分"的线性版没法合成一个 if（步长规则、状态、细化方式都不一样）。
///该用哪个由调用方按 _HiZEnabled 二选一（见 TracePassFragment）。
bool traceRayWithHiZ (float3 startVS, float3 reflectDirVS, float3 normalVS, out float2 hitPixel, out float marchPercent, out float hitZ,
    out float3 traceDebug)
{
    //调试用（正常路径不影响，只是多写一个 out 变量）：
    //白=命中、红=出屏、绿=过相机平面、蓝=步数用光；
    //走到终点的细分：黄=没截断且走完整条、橙=没截断但很早结束、品红=被近平面截断过
    traceDebug = 0;

    //**起点沿法线抬起来**（= 作者的 `rayOffset`，0.01 量级；他的签名就是 `HiZRayMarching(posVS, reflDirVS, normalVS, ...)`）。
    //  原作者调参经验：太大 ⇒ 出现"钳制范围"（自反射和步进不协调）；太小 ⇒ 自反射。
    //  它**替代**了原来那个 `inSelfBand` 补丁（"起点深度带内一律当空、不判命中"）：
    //  补丁是按**深度**划一条带 ⇒ 物体**根部**那个面几乎是**竖直**的、深度和起点几乎一样 ⇒ 整个根部一圈被当成"空"
    //  ⇒ **物体和它的倒影接不上（中间一条缝）**。沿法线把起点抬出来则不碰真交点，根部能正常判交。
    float3 rayStartVS = startVS + normalVS * _SSRRayOffset;

    //前半段和线性版 traceRay 一致：屏幕空间参数化 + 1/z 线性插值（透视投影下 1/z 沿屏幕上的直线是线性的）
    float2 startSS = ViewToScreenUV(rayStartVS);

    //射线**截断到近平面**（两篇参考文章都有这一步，我们之前漏了）：
    //朝相机飞的射线，终点可能落在相机背后 ⇒ ① ViewToScreenUV 的透视除法（除以≈0的 w）会给出垃圾 UV，
    //步长/深度基准全乱；② 射线会在几步内把 z 跨过 0 ⇒ 下面"越过相机平面就 return false"整条毙掉。
    //而步长越大越容易"一步跨过" ⇒ **mip 拉高之后成片丢反射，看着就是"图像被截断"**。
    float maxDistance = _SSRTotalRayLength;
    bool clamped = false;//调试用：这条射线有没有被近平面截断过
    if (reflectDirVS.z > 1e-6)//只有"朝相机飞"（视空间 z 在变大）才可能捅到背后；同时避免除零
    {
        float endVSZ = rayStartVS.z + reflectDirVS.z * maxDistance;
        float nearVSZ = -_ProjectionParams.y;//近平面的视空间 z（负值）
        if (endVSZ > nearVSZ)
        {
            maxDistance = (nearVSZ - rayStartVS.z) / reflectDirVS.z;//缩到正好停在近平面
            clamped = true;
        }
    }
    float3 endVS = rayStartVS + reflectDirVS * maxDistance;//射线总长（视空间米）
    float2 endSS = ViewToScreenUV(endVS);

    float2 bufferSizeXY = _CameraBufferSize.zw;
    if (length(startSS - endSS) < min(1 / bufferSizeXY.x, 1 / bufferSizeXY.y))//两点太近就给终点补 xy 各一像素
        endSS += 1 / bufferSizeXY;

    //**Hi-Z 的基准步长固定 = 1 个像素**（`_SSRPixelStride` 那套是给线性版的：线性版靠"大步宽 + 深度窗口大"
    //照样能判交，Hi-Z 不行 —— 当前级的格子只有 2^mip 像素宽，步长一旦超过一格，这一步跨过的中间那段
    //根本没被采到 ⇒ mip 越高漏得越多 ⇒ 树冠/叶片成片丢）。1 像素起步、每升一级翻倍 ⇒ 步长 = 格子宽，
    //"跨一格、看一格"，采到的那个格子正好盖住这一步走过的路。
    //（"能看多远"由 mip 级数 + _SSRStepCountLimit 决定：空旷处每升一级步长就翻倍）
    float2 deltaPixels = (endSS - startSS) * bufferSizeXY;
    float pixelsPerStep = 1.0;
    float screenSpan = max(abs(deltaPixels.x), abs(deltaPixels.y));
    int baseStepCount = max((int)ceil(screenSpan / pixelsPerStep), 1);
    float2 deltaSS = (endSS - startSS) / baseStepCount;

    //深度一律取"视空间米、正值"（和线性版的 intersect 同一口径）：1/-z 是这里的线性量
    float start1bz = 1.0 / -rayStartVS.z;
    float end1bz = 1.0 / -endVS.z;
    float delta1bz = (end1bz - start1bz) / baseStepCount;
    float total1bz = end1bz - start1bz;//整条射线在 1/z 上的跨度 ⇒ 用它反推"走了百分之多少"
    float invTotal1bz = 1.0 / (abs(total1bz) > 1e-6 ? total1bz : 1e-6);

    //起始抖动（和线性版同一个 4×4 表）：缓解"同一像素每帧都踩在同一个位置"的固定走样
    float2 currentSS = startSS;
    float current1bz = start1bz;
    float jitter = JitterDither(startSS * bufferSizeXY);
    currentSS += jitter * deltaSS;
    current1bz += jitter * delta1bz;

    hitZ = 0;	hitPixel = 0;	marchPercent = 1;//out 参数不会自动初始化，先把未命中时可能被读到的值定好

    float mipLevel = 0.0;
    [loop]
    for (int i = 0; i < _SSRStepCountLimit; i++)
    {
        //这一步跨多远：mip 每升 1 级，一个纹素覆盖的屏幕面积 ×4 ⇒ 步长 ×2
        float stepScale = exp2(mipLevel);
        //**这一步最多只能走到射线终点**：跨过去了就把它**缩到正好落在终点**（而不是把整步丢掉）。
        //（1/z 沿射线是线性的 ⇒ "还差几个基准步" = (end1bz - current1bz) / delta1bz；
        //  深度几乎不变（射线平行于视平面）时不夹，避免除零）
        float stepsToEnd = (abs(delta1bz) > 1e-12) ? (end1bz - current1bz) / delta1bz : 1e6;
        bool atRayEnd = stepsToEnd <= stepScale;
        if (atRayEnd)
        {
            stepScale = max(stepsToEnd, 0.0);
        }
        float2 nextSS = currentSS + deltaSS * stepScale;
        float next1bz = current1bz + delta1bz * stepScale;

        //**这一步的远端深度**（视空间米、正值，更深的那个）：门要用它。
        //深度在一步里可能变大也可能变小（朝相机飞的射线就在变小）⇒ 取 max 才是"远端"，否则判据会用反
        float rayFarZ = max(1.0 / current1bz, 1.0 / next1bz);

        //**先判"这一步有没有跨过射线终点"**（终点已经按近平面截断过）：
        //步长大时很容易一跨就跨过终点，而跨过终点之后 z 会翻到相机那一侧 ⇒
        //下面那句"越过相机平面就 return false"会把**其实还没走到终点**的射线提前毙掉
        //（实测：缺失区域大部分就是它 —— 染色里的"绿色"）。
        //1/z 沿射线是单调的，所以用"和终点 1/z 的相对方向"判即可（两个方向都成立）。
        if (!atRayEnd && (next1bz - end1bz) * (end1bz - start1bz) > 0)
        {
            //兜底（上面已经把步长夹到终点，正常到不了这里）
            //调试细分（三种颜色，能看出"是谁把这条射线结束掉的"）：
            //  品红 = 这条射线**被近平面截断过**（本来就短，眼睛看不到的内容）
            //  黄   = 没被截断、而且**几乎走完了整条射线**（= 允许的长度内真的没东西）
            //  橙   = 没被截断、但**很早就结束了**（= 一步跨过了终点 / 射线被别的原因截短）
            float walked = saturate((current1bz - start1bz) * invTotal1bz);//这条走了整条射线的百分之多少
            traceDebug = clamped ? float3(1, 0, 1)
                : (walked > 0.9 ? float3(1, 1, 0) : float3(1, 0.5, 0));
            return false;//已经走到（或越过）射线允许的终点
        }

        if (nextSS.x < 0 || nextSS.x > 1 || nextSS.y < 0 || nextSS.y > 1)
        {
            //走出屏幕：**先退档，再判死**。mip 大时"第一步就跨出屏幕"很常见（掠射的反射尤其容易），
            //那种情况不该把整条射线放弃（否则屏幕边缘会整块丢反射）；
            //缩小步长、退回来重试，只有连最细一级都还在往外走，才算真的取不到了。
            if (mipLevel > 0.5)
            {
                mipLevel -= 1.0;
                continue;
            }
            traceDebug = float3(1, 0, 0);//调试：红 = 终点走出屏幕（已退到最细一级）
            return false;
        }
        if (rayFarZ <= 0)
        {
            //兜底：上面的"终点判据"应该已经挡掉了绝大多数情况（终点被截断在近平面之内）
            traceDebug = float3(0, 1, 0);//调试：绿 = 越过相机平面
            return false;//射线越过相机平面（背后那块画面不在屏幕上）
        }

        //采样点取这一步的**中点**，不是末端 —— 和线性版（currentSS + 0.5 * deltaSS）同一个口径。
        //采末端时，看的是"前方一格"：命中位置天然比真实交点晚半步（物体边缘尤其明显）；采中点才
        //落在这一步**之内**。⚠️ 代价是"判据锚点"跟着变了：原来 rayNearZ/rayFarZ 就是采样点的前后，
        //现在采样点在中间 ⇒ mip0 的确认判据必须一起锚到采样点（见下），否则会多出提前半格的假命中。
        float2 sampleSS = currentSS + deltaSS * (0.5 * stepScale);
        float sample1bz = current1bz + 0.5 * delta1bz * stepScale;
        float sampleZ = 1.0 / sample1bz;//射线在**采样点**处的视深度（判据要在同一个点上，见下面 mip0 那段）
        //**每步采两格**（这一步的**中点** + **末端**）：一格的覆盖范围只有一格，而采样点落在这一格里的位置
        //是随机的 ⇒ 只采一格时，对齐最差的地方这一步有**一半**没被采到，那半格里的东西就被当成"空"跳过去了
        //（远处细长目标的反射因此表现为"条纹状缺失"，mip 越高条纹越宽）。两点相距半格 ⇒ 两格的覆盖互补，
        //合起来一定盖住这一整步。代价 = 每轮多一次采样（**不多一轮迭代**）。
        //取两者中**更近**的那个（ReverseZ：值大 = 近）当判据 ⇒ 偏保守（更容易降档），但不会漏。
        float rawHiZMid = SAMPLE_TEXTURE2D_LOD(_HiZTex, sampler_point_clamp, sampleSS, mipLevel).r;
        float rawHiZEnd = SAMPLE_TEXTURE2D_LOD(_HiZTex, sampler_point_clamp, nextSS, mipLevel).r;
        float rawHiZ = max(rawHiZMid, rawHiZEnd);
        //那一块里"离相机最近"的表面深度（保守 ⇒ 说"这块没东西"就真的没东西）
        float surfaceZ = LinearEyeDepth(rawHiZ, _ZBufferParams);

        //（这里原来有个 `inSelfBand` 补丁："射线在深度上还没离开起点一个厚度之内 ⇒ 一律当空、不判命中"。
        //  它把**物体根部**那一圈真反射也一起当掉了（根部那个面几乎竖直、深度和起点几乎一样）
        //  ⇒ 物体和它的倒影接不上（中间一条缝）。现在改用"起点沿法线抬起 `rayOffset`"治自交 ⇒ 补丁已删除。）
        //**门的判据一定用"这一步的远端"**（保守：只有整步都还在面**前面**时，才敢说"这块没东西"、才敢升档）。
        //⚠️⚠️ 曾经试过照搬原文那句门（"**采样点**已越过面 ⇒ 才算碰到"）：**实测立刻出现大量条纹状缺失**。
        //  原因：原文的采样点是在**步进前方半步**（他先迈进再算 `currInvW + 半步`），所以"采样点越过" = 未来那一点越过 ⇒ 保守；
        //  而我们是在这一步的**中点**采样（落后半步）⇒ 同一句话就变成"当前中点正越过" ⇒ 步末那段还没测就把整步放行
        //  ⇒ 一步跳过去 ⇒ 条纹。（两边的 near/far 定义也整体错开半步，不能逐字抄。）
        if (rayFarZ > surfaceZ)//这一步的远端越过了这一块里最近的表面 ⇒ 这一步可能跨过了它
        {
            if (mipLevel > 0.5)
            {
                mipLevel -= 1.0;//还有更细的级：这一步不算数、退回起点、降一级重走
                continue;
            }
            //已经是最细一级：判"**这一步跨过了这个面**" —— 门已经保证"远端越过"，
            //  这里只要面还落在**采样点 ± 一个厚度**之内（前后都算 ⇒ 用 abs）就算命中。
            //  为什么改成"前后都算"（原文那层意思）：粗一点的位置上，面往往正好落在采样点**前面一点点**、
            //  却被这一步的远端跨过去了 —— 只在"已经钻进面里"才算会把它整条漏掉（这就是原来的漏/断层）。
            //  窗口仍然只放宽到"± 一个厚度"（不是整步的深度跨度）⇒ 不会像"用步子两端当窗口"那样在掠射处到处假命中。
            if (abs(surfaceZ - sampleZ) < _SSRPixelThickness)
            {
                //⚠️ 这里曾经试过"在这一步内做 6 次二分"把命中位置细化到亚像素（照搬线性版那套），
                //   实测**看不出区别** ⇒ 已回退。原因是区间太小（半步 = 半个 trace 像素 = 1 个全分辨率像素），
                //   而且反射内容的"台阶"来自**追踪整体是半分辨率**（每个 trace 像素盖 2×2 全屏像素），
                //   亚像素细化只挪 1 个像素，改变不了内容的分辨率上限。真要更细只能提高追踪分辨率。
                hitPixel = sampleSS;
                //进度直接取 1/z 上的参数（用**采样点**，不是步子末端）：它就是"走了整条射线的百分之多少"
                marchPercent = saturate((current1bz + 0.5 * delta1bz * stepScale - start1bz) * invTotal1bz);
                hitZ = surfaceZ;
                traceDebug = float3(1, 1, 1);//调试：白 = 命中
                return true;
            }
            //最细一级但不在窗口内（面离采样点超过一个厚度）：继续往前小步走
        }
        else
        {
            //这一整块都没东西 ⇒ 放心大步走：升一级（步长翻倍，最多 _MaxHiZMipLevel）
            mipLevel = min(mipLevel + 1.0, (float)_MaxHiZMipLevel);
        }

        //这一步已经是"贴着终点"的最后一步：在终点查过、没命中就收工（不这样的话会继续跑到射线长度之外）
        if (atRayEnd)
        {
            traceDebug = float3(1, 1, 0);//调试：黄 = 走完了整条射线
            return false;
        }

        currentSS = nextSS;
        current1bz = next1bz;
    }

    traceDebug = float3(0, 0, 1);//调试：蓝 = 步数用光、循环自然结束
    return false;
}

//命中的"可信度"（四项淡出），返回值当 alpha 用：0 = 别用这次命中，1 = 完全相信
float alphaCalc(float3 rayDirection, float2 hitPixel, float marchPercent, float hitZ)
{
    float res = 1;

    //反射方向朝相机的淡出：viewZ≤0（朝远处）全亮，viewZ 越正（越朝相机飞来）越淡，达到 _SSRBackRayFadeWidth 完全消失
    //镜子里应该看到相机背后/贴近相机的东西，而那块画面根本不在屏幕上，SSR 无论如何都取不到，只会取到错误的像素，所以拦掉
    res *= saturate(1.0 - rayDirection.z / max(_SSRBackRayFadeWidth, 0.001));

    //屏幕边缘淡出（已换成暗角式，见下）：原来那套用"屏幕中心=0、屏幕边缘=1"的归一化半径衡量，超过 _SSRScreenEdgeFadeStart 开始淡出
    //**"暗角"式**：用"离屏幕中心的**半径**"（椭圆）而不是"x/y 里谁大"（方框）；曲线换成幂次平滑
    //（中心附近几乎不动、靠边迅速掉到 0），不再有"开始淡出"那条可见折线。
    //  · _SSREdgeFadeScale（原始 1.8）：距离倍率。屏幕边框上 att≈0.9 ⇒ (1-0.81)^5≈0.0002，基本已经淡没；
    //    反射被削太多就把这个调小（1.4 左右）。
    //  · _SSREdgeFadeAttenuation（原始 1）：距离的整形幂（>1 更集中在中心）。
    float2 attUV = abs(hitPixel - 0.5) * _SSREdgeFadeScale;
    attUV = pow(saturate(attUV), max(_SSREdgeFadeAttenuation, 0.001));
    float att = length(attUV);
    res *= pow(saturate(1.0 - att * att), 5.0);

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

    //3.沿反射方向在屏幕空间步进找交点：优先用 Hi-Z（按 mip 升降步长，同样的步数能走得更远）。
    //   **两个条件都满足**才用 Hi-Z：`_HiZEnabled` = 资源这帧有没有（HierarchicalZ 上传，没建就绑黑图）；
    //   `_SSRUseHiZ` = SSR 自己想不想用（设置里的开关）。任一个为假 ⇒ 退回线性步进（等步长 + 末尾二分）。
    //   ⚠️ 用 if/else 而不是三目：两个函数都往同一组 out 参数里写，三目在 HLSL 里可能两边都求值。
    float2 hitPixel;
    float marchPercent;
    float hitZ;
    float3 traceDebug = 0;//调试用（见文件头的 SSR_TRACE_DEBUG 说明）
    bool hit;
    if (_HiZEnabled > 0.5 && _SSRUseHiZ > 0.5)
    {
        hit = traceRayWithHiZ(startVS, reflectDirVS, normalVS, hitPixel, marchPercent, hitZ, traceDebug);
    }
    else
    {
        hit = traceRay(startVS, reflectDirVS, hitPixel, marchPercent, hitZ);
    }

    #if defined(SSR_TRACE_DEBUG)
        //调试：不输出反射，直接把"这条射线为什么结束"画出来
        //（白=命中 / 红=走出屏幕 / 绿=越过相机平面 / 蓝=步数用光 / 黑=起点就没有面）
        return float4(traceDebug, 1.0);
    #endif

    if (!hit)
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
