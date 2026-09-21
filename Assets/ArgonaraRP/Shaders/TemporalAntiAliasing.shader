//时域抗锯齿（TAA）：把本帧颜色和**上一帧累积的结果**混合。靠每帧的亚像素抖动（C# 直接改投影矩阵）
//把 8 帧铺成"一个像素内 8 次采样"⇒ 静态画面越来越干净。
//
//Pass 顺序：C# 按 pass 索引调用（见 TemporalAntiAliasing.cs 的 Pass 枚举），两边必须一致：
//  0 = TAA
//
//输入全是 C# 每帧 SetGlobal* 绑的（名字见 TemporalAntiAliasing.cs）：
//  _SourceTexture      本帧颜色（颜色附件）        _HistoryTex        上一帧的累积结果（跨帧持久，双缓冲）
//  _CameraDepthTexture 本帧深度（项目那份可读的深度拷贝；渲染器按 TAA 需要强制开了它）
//  _TAATexelSize       (1/宽,1/高,宽,高)           _TAAPrevViewProj   上一帧 VP（**未抖动**）
//  _TAAJitter          本帧抖动（UV 单位）         _TAAResetHistory   1 = 这帧不要历史
//  _TAABlendFactor / _TAAMotionBlendScale  混合权重   _TAASharpenStrength  可选锐化（0 = 关）
//
//本版是**仅重投影**（没有运动矢量）：本帧像素 → 世界 → 上一帧 VP → 历史 uv，
//再把它**加上本帧抖动**，让历史落回"本像素自己"（不加的话每帧都落在"亚像素偏移处"、偏移量还每帧不同 ⇒ 反馈回路里等于每帧做一次低通 ⇒ 糊）。
Shader "Hidden/ArgonaraRP/Temporal Anti Aliasing"
{
    SubShader
    {
        //全屏绘制：不剔除、不做深度测试、不写深度（和 SSR / HiZ / PCSS 一致）
        Cull Off
        ZTest Always
        ZWrite Off

        HLSLINCLUDE
        #include "../ShaderLibrary/Common.hlsl"
        //DefaultPassVertex（全屏三角）以及 _SourceTexture / _CameraDepthTexture 等声明都在这里
        #include "CameraRendererPasses.hlsl"

        //上一帧的累积结果：跨帧持久的双缓冲图，C# 里"读哪张"由索引决定
        TEXTURE2D(_HistoryTex);

        float4 _TAATexelSize;       //(1/宽, 1/高, 宽, 高)：3×3 邻域取邻居用它
        float4 _TAAJitter;          //本帧抖动（UV 单位）
        float4x4 _TAAPrevViewProj;  //上一帧 VP（未抖动、GPU 口径，和 unity_MatrixInvVP 对偶）
        int _TAAResetHistory;       //1 = 这帧只输出当前帧（首帧 / 刚重建 / 相机瞬移）
        float _TAABlendFactor;      //当前帧的基础权重：越小越信历史（越稳，也越容易鬼影）
        float _TAAMotionBlendScale; //"动得越多越信当前帧"的放大系数
        float _TAASharpenStrength;  //可选锐化强度（0 = 关）：复用 3×3 邻域均值做 unsharp mask

        //=========================================================
        //====== 运动矢量那条路（还没做：以后接了 _CameraMotionVectorsTexture 再打开）======
        //=========================================================
        //打开它就切到原版的"采运动矢量"那条路（historyUV = uv - 运动矢量，而不是重投影）：
        //#define TAA_MOTION_VECTORS

        #if defined(TAA_MOTION_VECTORS)
        TEXTURE2D(_CameraMotionVectorsTexture);
        float4 _CameraDepthTexture_TexelSize;

        //像素在物体边缘时，这个像素的运动矢量可能来自背景（深度上是后面的那个面）⇒ 用"最近的邻居"去采
        float2 GetClosestFragment (float2 uv)
        {
            float2 k = _CameraDepthTexture_TexelSize.xy;
            const float4 neighborhood = float4(
                SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, (uv - k)),
                SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, (uv + float2(k.x, -k.y))),
                SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, (uv + float2(-k.x, k.y))),
                SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, (uv + k))
            );
            #if UNITY_REVERSED_Z
                #define COMPARE_DEPTH(a, b) step(b, a)
            #else
                #define COMPARE_DEPTH(a, b) step(a, b)
            #endif
            float3 result = float3(0.0, 0.0, SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv));
            result = lerp(result, float3(-1.0, -1.0, neighborhood.x), COMPARE_DEPTH(neighborhood.x, result.z));
            result = lerp(result, float3( 1.0, -1.0, neighborhood.y), COMPARE_DEPTH(neighborhood.y, result.z));
            result = lerp(result, float3(-1.0,  1.0, neighborhood.z), COMPARE_DEPTH(neighborhood.z, result.z));
            result = lerp(result, float3( 1.0,  1.0, neighborhood.w), COMPARE_DEPTH(neighborhood.w, result.z));
            return (uv + result.xy * k);
        }
        #endif

        //=========================================================
        //====== AABB 邻域裁剪（YCoCg 里做）======
        //=========================================================
        //3×3 邻域的九个偏移
        static const float2 kOffsets3x3[9] =
        {
            float2(-1, -1), float2(0, -1), float2(1, -1),
            float2(-1,  0), float2(0,  0), float2(1,  0),
            float2(-1,  1), float2(0,  1), float2(1,  1),
        };

        //YCoCg：亮度（Y）和色度（Co/Cg）分开 ⇒ 在色度上裁剪时，亮度的高频不会被色度的偏差带跑
        //（名字带 TAA 后缀：SRP core 的 Color.hlsl 里已经有同名函数了，两个只是"归一化 + 色度偏置"不同，
        //  对 AABB 裁剪的结果没有影响 —— 这里保持原版的写法，别混用）
        float3 TaaRGBToYCoCg (float3 RGB)
        {
            return float3(
                dot(RGB, float3(1, 2, 1)),
                dot(RGB, float3(2, 0, -2)),
                dot(RGB, float3(-1, 2, -1))
            );
        }

        float3 TaaYCoCgToRGB (float3 YCoCg)
        {
            float Y  = YCoCg.x * 0.25;
            float Co = YCoCg.y * 0.25;
            float Cg = YCoCg.z * 0.25;
            return float3(Y + Co - Cg, Y + Cg, Y - Co - Cg);
        }

        //临时压缩 / 还原（Reinhard）：混合和 AABB 都在 0~1 的"友好区间"里做，输出前再还原回 HDR。
        //（就是文章的「Reinhard → TAA → 还原 HDR」；都是逐像素的数学，所以直接写在这一趟里，不用多两趟绘制）
        float3 TaaReinhard (float3 c)
        {
            c = max(c, 0.0);//负值（SSR/滤镜/锐化可能产生）会让压缩失去意义，先夹掉
            return c / (1.0 + c);
        }

        float3 TaaInverseReinhard (float3 c)
        {
            c = clamp(c, 0.0, 0.999);//y → 1 时 1-y → 0 会爆，夹一下
            return c / (1.0 - c);
        }

        //把历史色朝"AABB 的中点"拉回来，直到落进盒子（不是硬 clamp：连续变化，不会突然跳色）
        float3 ClipHistory (float3 History, float3 BoxMin, float3 BoxMax)
        {
            float3 Filtered = (BoxMin + BoxMax) * 0.5;
            float3 RayOrigin = History;
            float3 RayDir = Filtered - History;
            RayDir = abs(RayDir) < (1.0 / 65536.0) ? (1.0 / 65536.0) : RayDir;//别除以 0
            float3 InvRayDir = 1.0 / RayDir;
            float3 MinIntersect = (BoxMin - RayOrigin) * InvRayDir;
            float3 MaxIntersect = (BoxMax - RayOrigin) * InvRayDir;
            float3 EnterIntersect = min(MinIntersect, MaxIntersect);
            float ClipBlend = saturate(max(EnterIntersect.x, max(EnterIntersect.y, EnterIntersect.z)));
            return lerp(History, Filtered, ClipBlend);
        }

        //=========================================================
        //====== 0.TAA ======
        //=========================================================
        float4 TaaPassFragment (Varyings input) : SV_Target
        {
            float2 uv = input.screenUV;
            float4 color = SAMPLE_TEXTURE2D_LOD(_SourceTexture, sampler_linear_clamp, uv, 0);

            //首帧 / 刚重建 / 相机瞬移：历史不可信，这帧只输出当前帧（下一帧开始才混）
            if (_TAAResetHistory)
            {
                return color;
            }

            //重投影：本像素的世界坐标 → 上一帧 VP → 上一帧屏幕 uv
            //（重建用 unity_MatrixInvVP，它就是"本帧抖过的 VP"的逆，和深度图同口径）
            float rawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
            float3 positionWS = ScreenSpaceWorldPosFromDepth(uv, rawDepth);
            float4 prevClip = mul(_TAAPrevViewProj, float4(positionWS, 1.0));
            float2 historyUV = prevClip.xy / prevClip.w * 0.5 + 0.5;
            #if UNITY_UV_STARTS_AT_TOP
                historyUV.y = 1.0 - historyUV.y;//和 ScreenSpaceWorldPosFromDepth 里那次 y 取反对应
            #endif

            //把**本帧的抖动**加回去：本帧这个像素采的是"未抖动位置 p − j"那个表面点，
            //而 _TAAPrevViewProj 是未抖动的 ⇒ 投回来自然也是 p − j；再加上 j 才正好落在**本像素**自己身上。
            historyUV += _TAAJitter.xy;

            #if defined(TAA_MOTION_VECTORS)
                float2 motion = SAMPLE_TEXTURE2D_LOD(_CameraMotionVectorsTexture, sampler_point_clamp,
                    GetClosestFragment(uv), 0).rg;
                historyUV = uv - motion;
            #else
                float2 motion = uv - historyUV;//重投影出来的"运动"（uv 单位，和运动矢量同口径）
            #endif

            float4 historyColor = SAMPLE_TEXTURE2D_LOD(_HistoryTex, sampler_linear_clamp, historyUV, 0);

            //=== 压缩域（Reinhard）：本帧色和历史色都先压到 0~1，AABB / 裁剪 / 混合全在这上面做 ===
            //（亮部不再发散 ⇒ 高光的鬼影/拖影明显变少；输出前再还原回 HDR）
            float3 colorC = TaaReinhard(color.rgb);
            float3 historyC = TaaReinhard(historyColor.rgb);

            //3×3 邻域 AABB（压缩值）：历史色跟当前帧这一带差太多（换了物体/被遮住/鬼影）就把它拉回盒子里
            //（顺手把邻域和攒起来给下面的锐化用，不用再采一遍）
            float3 boxMin, boxMax, neighborhoodSum = 0.0;
            boxMax = boxMin = TaaRGBToYCoCg(colorC);
            [unroll]
            for (int k = 0; k < 9; k++)
            {
                float3 sampled = SAMPLE_TEXTURE2D_LOD(_SourceTexture, sampler_linear_clamp,
                    uv + _TAATexelSize.xy * kOffsets3x3[k], 0).rgb;
                neighborhoodSum += sampled;
                float3 c = TaaRGBToYCoCg(TaaReinhard(sampled));
                boxMin = min(boxMin, c);
                boxMax = max(boxMax, c);
            }
            historyC = TaaYCoCgToRGB(ClipHistory(TaaRGBToYCoCg(historyC), boxMin, boxMax));

            //当前帧权重：基础值 + 动得越多越信当前帧（历史 uv 出屏 = 这像素上一帧不在画面里 ⇒ 全用当前帧）
            float blend = saturate(_TAABlendFactor + length(motion) * _TAAMotionBlendScale);
            if (historyUV.x < 0.0 || historyUV.y < 0.0 || historyUV.x > 1.0 || historyUV.y > 1.0)
            {
                blend = 1.0;
            }

            //混合（在压缩域里）→ 还原回 HDR
            float3 result = TaaInverseReinhard(lerp(historyC, colorC, blend));

            //锐化（可选，0 = 关）：TAA 是"多帧平均"，天然偏软 ⇒ 用邻域均值做一次 unsharp mask 补回来。
            //（用的是**当前帧**的邻域，抽头就是上面那 9 个，不额外采样；建议 0.1~0.4，开太大白边/过冲明显）
            if (_TAASharpenStrength > 0.0)
            {
                float3 neighborhood = neighborhoodSum * (1.0 / 9.0);//邻域均值仍取**未压缩**的（和之前手感一致）
                result = max(result + (result - neighborhood) * _TAASharpenStrength, 0.0);
            }

            return float4(result, lerp(historyColor.a, color.a, blend));
        }
        ENDHLSL

        Pass
        {
            Name "TAA"

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment TaaPassFragment
            ENDHLSL
        }
    }
}
