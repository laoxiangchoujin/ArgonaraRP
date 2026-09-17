//第3步：屏幕空间 PCSS 阴影图
//把"逐像素几十次采样的 PCSS"从 Deferred Lighting 里挪出来，单独算一遍写成一张屏幕纹理，
//最后光照 Pass 只采样一次这张纹理（还能顺带做半分辨率）。
//
//绘制顺序（都在 GBuffer 之后、Deferred Lighting 之前）：
//  GBuffer
//   → ① 半影mask（1/4分辨率，判定"阴影/半影/非阴影"）
//   → ②③ mask横/竖两趟箱式blur（把半影带扩宽）
//   → ④ PCSS（查mask：0/1直接返回，只有半影带里才真跑）
//   → ⑤⑥ 结果图横/竖两趟双边blur（给带子里的PCSS噪声去噪）
//   → Deferred Lighting
//半分辨率纹理对：_ScreenSpaceShadowTex（结果）、_ScreenSpaceShadowTex_TempBlur（⑤⑥之间倒手）
//1/4分辨率纹理对：_ScreenSpaceShadowMaskTex（mask）、_ScreenSpaceShadowMaskTexTemp（②③之间倒手）
//（同一张纹理不能在同一次绘制里既读又写，所以blur都要有倒手图）。
//
//这些 Pass 都是由 CommandBuffer.DrawProcedural 手动绘制的（和 CameraRenderer.shader 一样），
//所以只需要 Name（靠材质 + pass索引来调用），不需要 LightMode 之类的 tag：
//  - 不参与 Unity 的渲染队列 / 灯光模式匹配 → 不需要 "LightMode"
//  - 本管线现有 shader 都没有 "RenderPipeline" tag，加了反而可能被跳过 → 也不加
//另外三个 Pass 的渲染状态在 SubShader 里统一设置（全屏绘制：不剔除、不做深度测试、不写深度）。
Shader "Hidden/ArgonaraRP/Screen Space PCSS"
{
    SubShader
    {
        Cull Off
        ZTest Always
        ZWrite Off

        HLSLINCLUDE
        #include "../ShaderLibrary/Common.hlsl"
        //DefaultPassVertex（全屏三角）以及 _GBuffer1~4 / _CameraDepthTexture 等声明都在这个文件里
        #include "CameraRendererPasses.hlsl"

        //=========================================================
        //====== 双边模糊（保边）共用的小工具 ======
        //横向/纵向blur都用它：除了"空间距离"（二项式权重），再乘两个"差异"权重 —— 深度差 + 法线夹角，
        //这样跨物体边界、跨不同朝向的面时不会把阴影糊过去（否则会漏光、出现亮边、近遮挡处被糊软）。
        //=========================================================

        //【mask那一对的纹素尺寸】xy = 1/宽、1/高（zw = 宽、高）。C# 按 mask（1/4分辨率）的尺寸上传。
        //1个mask纹素 = 4个屏幕纹素；反过来也能从它推出"1个屏幕像素"的uv长度 = 它 × 0.25（mask那趟找4×4子像素要用）
        float4 _ScreenSpaceShadowTexelSize;
        //【结果图那一对的纹素尺寸】给下面两趟双边blur用（结果图是半分辨率，和mask不是同一套尺寸）
        float4 _ScreenSpaceShadowResultTexelSize;

        //半影mask：1/4分辨率，0 = 全遮、1 = 全亮、中间 = 半影（akg/原神那套）。由 C# 每帧 SetGlobalTexture 绑定
        TEXTURE2D(_ScreenSpaceShadowMaskTex);

        //mask 的判据阈值 MASK_BAND_MIN_TEXELS 定义在 Shadows.hlsl 里（共享库，那边才能被看到）

        //mask blur 的调参（想接成管线设置以后再说）：
        //带子宽度**不再**由它决定（判据直接按本地半影算），这里负责"抹平带子边界的1/4分辨率块状感 +
        //给带子外圈留一条保守余量"。akg 原文就是 ±3。
        //调大 = 带子边界更平滑、PCSS覆盖面更宽（更贵）；调小 = 更省，但边界会更"硬"、颗粒感更明显。
        #define MASK_BLUR_RADIUS 3        //±3 = 7抽头（横竖两趟合起来 7×7）
        //距离补偿（akg那个"越近半径越大"的系数）：**默认关**，先保证正确性。
        //原因：radius 乘的是"抽头间距"，间距一大就变成稀疏采样 —— 7个抽头撒在几百个屏幕像素上，
        //mask会被拉出条纹/斑块（表现就是阴影变形、拉伸，镜头离得越近越明显）。要试就打开，并把MAX压在2以内。
        #define MASK_BLUR_DISTANCE_COMPENSATION 0
        #define MASK_BLUR_FALLOFF 0.01    //距离系数 = 1/(d²·falloff + falloff)
        #define MASK_BLUR_RADIUS_MIN 1.0  //下限1 = 普通箱式（抽头间距 = 1个mask纹素）
        #define MASK_BLUR_RADIUS_MAX 2.0  //上限别放大：抽头间距=2个mask纹素已经在稀疏采样的边缘了

        //（"屏幕UV + 原始深度 → 世界坐标"用公共工具 ScreenSpaceWorldPosFromDepth，见 Fragment.hlsl）

        //本管线当前是前向还是延迟：1=延迟、0=前向（各自的渲染器每帧设置）。
        //用来区分"用途相同但名字不同"的纹理：延迟的法线在 _GBuffer2，前向的在 _CameraNormalsTexture（DepthNormals prepass输出）。
        
        TEXTURE2D(_CameraNormalsTexture);

        //取当前场景的**着色法线**（含法线贴图）：延迟读 GBuffer2，前向读 DepthNormals prepass 输出的法线图。
        //编码统一是 "normal * 0.5 + 0.5"，所以解码方式一样，两条路的**口径也一致**（都是着色法线）。
        //用途：① 两趟 blur 的"法线保边项"；② 给 ScreenSpaceGeometricNormal 当翻正参考。
        //（阴影 bias 要的**几何法线**是那边从深度重构出来的，不读这张图）
        float3 ScreenSpaceSceneNormal (float2 uv)
        {
            float3 encoded = (_UseDeferredRenderer > 0)
                ? SAMPLE_TEXTURE2D(_GBuffer2, sampler_point_clamp, uv).xyz
                : SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_point_clamp, uv).xyz;
            return normalize(encoded * 2.0 - 1.0);
        }

        //邻居像素的双边权重：0 = 完全不算它，1 = 完全按空间权重算
        float BilateralWeight (float2 uvNeighbor, float3 posCenter, float3 normalCenter, float depthTolerance)
        {
            float rawDepthN = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uvNeighbor);
            if (rawDepthN < 1e-5)//邻居是天空：不参与，否则物体轮廓外会出现一圈亮边
            {
                return 0.0;
            }

            //深度项：用世界坐标距离（比直接比深度更准确，斜面上也成立）
            float3 posN = ScreenSpaceWorldPosFromDepth(uvNeighbor, rawDepthN);
            float wDepth = saturate(1.0 - length(posN - posCenter) / depthTolerance);

            //法线项：朝向差得多就不混（深度接近但朝向不同的地方全靠它，比如地面与竖墙交界）
            float3 normalN = ScreenSpaceSceneNormal(uvNeighbor);
            float wNormal = pow(saturate(dot(normalCenter, normalN)), 16.0);

            return wDepth * wNormal;
        }
        ENDHLSL

        //1.生成：读深度重建世界坐标 + 读 GBuffer 法线 → 伪造 Surface → 只算主定向光的实时阴影（主光自动走PCSS）
        //       结果写入 _ScreenSpaceShadowTex
        Pass
        {
            Name "PCSS"

            HLSLPROGRAM
            #pragma target 3.5
            //这两个是全局关键字（Shadows.cs 每帧设置），屏幕空间这一遍必须和光照Pass用同一套，否则走不到PCSS
            #pragma multi_compile _ _DIRECTIONAL_PCSS
            #pragma multi_compile _ _SHADOW_PCF3 _SHADOW_PCF5 _SHADOW_PCF7
            //和 Deferred Lighting 一样受"是否接收阴影"这个关键字控制（关掉就整张图返回1）
            #pragma multi_compile _ _RECEIVE_SHADOWS

            //本Pass是写入 _ScreenSpaceShadowTex（渲染目标由 SetRenderTarget 指定），不需要把它声明成贴图

            #pragma vertex DefaultPassVertex
            #pragma fragment ScreenSpaceShadowPassFragment

            float ScreenSpaceShadowPassFragment(Varyings input) : SV_Target
            {
                //和 Deferred Lighting 一致：不接收阴影就直接返回1（完全照亮），后面光照Pass也会early-out
                //（没有直接调用 GetDirectionalShadowAttenuation：它会把"烘焙阴影混合 + 强度衰减"也算进结果里，
                //  那两件事要留在光照Pass做，否则以后会算两遍）
                // #if !defined(_RECEIVE_SHADOWS)
                //     return 1.0;
                // #endif

                float2 uv = input.screenUV;

                //背景/天空没有接收面：直接返回1（完全照亮），blur时也不会把邻域带坏
                float rawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
                if (rawDepth < 0.00001 || GetDirectionalLightCount() == 0)
                {
                    return 1.0;
                }

                //半影mask（akg/原神那套）：0 = 必然全遮、1 = 必然全亮，只有中间的"半影带"才值得跑PCSS。
                //mask是1/4分辨率、而且被箱式模糊**故意扩宽**过，所以这里用linear采样（带子平滑），
                //阈值留一点余量：报错方向永远是"多算一点PCSS"，而不是"该软的地方变硬"。
                //（省下的不止是blocker+PCF：下面重建世界坐标、造Surface、选级联也一并跳过了）
                float penumbraMask = SAMPLE_TEXTURE2D(_ScreenSpaceShadowMaskTex, sampler_linear_clamp, uv).r;
                if (penumbraMask >= 1.0 - 1e-3)
                {
                    return 1.0;
                }
                if (penumbraMask <= 1e-3)
                {
                    return 0.0;
                }

                //深度图重建世界坐标（公共工具，见 Fragment.hlsl）
                float3 posWS = ScreenSpaceWorldPosFromDepth(uv, rawDepth);

                //伪造一个 Surface：阴影那套函数只要这几个字段（position/depth/dither/interpolatedNormal），
                //其余字段它们不读，给中立值即可（顺便省掉 GBuffer1/GBuffer3 的两次采样）
                Surface surfaceWS;
                surfaceWS.position = posWS;
                //视空间深度（米）：GetShadowData 里的距离淡出 FadedShadowStrength 要的是这个，
                //下面的几何法线也要用（注意不能用原始深度值充当 depth，那样对距离淡出是错的）
                surfaceWS.depth = -TransformWorldToView(surfaceWS.position).z;
                float3 normal = ScreenSpaceSceneNormal(uv);//延迟从GBuffer2、前向从_CameraNormalsTexture
                surfaceWS.normal = normal;
                //PCSS 的 bias 法线要"几何面法线"（不含法线图扰动）：和延迟光照 pass 同一个函数、同一口径
                surfaceWS.interpolatedNormal = ScreenSpaceGeometricNormal(surfaceWS.position, surfaceWS.depth, normal, uv);
                surfaceWS.viewDirection = normalize(_WorldSpaceCameraPos - surfaceWS.position);
                surfaceWS.dither = InterleavedGradientNoise(input.positionCS_SS.xy, 0);//cascade blend 的 Dither 模式要用
                surfaceWS.albedo = 0.0;
                surfaceWS.alpha = 1.0;
                surfaceWS.roughness = 0.0;
                surfaceWS.metallic = 0.0;
                surfaceWS.occlusion = 1.0;
                surfaceWS.renderingLayerMask = 0;

                ShadowData shadowData = GetShadowData(surfaceWS);//算级联索引 + 距离淡出强度
                //主定向光 = 第一个定向光（PCSS 也只对它生效）
                DirectionalShadowData directional = GetDirectionalShadowData(0, shadowData);
                //实时阴影完全不可用（超出最大级联距离，或该光没有阴影强度）：沿用光照Pass的判据直接返回1。
                //光照Pass遇到这种情况会去采烘焙阴影，和这张图无关。
                if (directional.strength * shadowData.strength <= 0.0)
                {
                    return 1.0;
                }

                //只算"实时"这一半：GetCascadedShadow 内部对主光会自动走 PCSSDirectionalShadow，并处理级联间的过渡。
                //这里故意不调用 GetDirectionalShadowAttenuation：它开头是 #if !defined(_RECEIVE_SHADOWS) return 1.0，
                //而 _RECEIVE_SHADOWS 是材质关键字，这个全屏材质上未必开着 → 会让整个Pass白算。
                //烘焙阴影的混合、阴影强度的衰减都留在光照Pass里做：那边把"GetCascadedShadow"这一步换成采样这张图即可。
                return GetCascadedShadow(directional, shadowData, surfaceWS);
            }
            ENDHLSL
        }

        //2.横向模糊：_ScreenSpaceShadowTex → _ScreenSpaceShadowTex_TempBlur
        Pass
        {
            Name "Blur Horizontal"

            HLSLPROGRAM
            #pragma target 3.5

            //TEXTURE2D(_ScreenSpaceShadowTex);
            //↑ 保持注释：Shadows.hlsl（随 CameraRendererPasses.hlsl 一起被include）里已经声明过它了，重复声明会报"重复定义"

            #pragma vertex DefaultPassVertex
            #pragma fragment BlurHorizontalPassFragment

            float BlurHorizontalPassFragment(Varyings input) : SV_Target
            {
                float2 uv = input.screenUV;
                //这张图自己的纹素尺寸（半分辨率 ⇒ 是屏幕纹素的2倍），横向取x
                float texelX = _ScreenSpaceShadowResultTexelSize.x;

                float rawDepthC = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
                if (rawDepthC < 1e-5)
                {
                    return 1.0;//天空：pass0写进去的就是1
                }

                float3 posC = ScreenSpaceWorldPosFromDepth(uv, rawDepthC);
                float3 normalC = ScreenSpaceSceneNormal(uv);
                //深度容差 = 视深度的 5%（随距离线性放大，避免远处把该保留的边界也糊掉）。想更"保边"就调小
                float depthTolerance = max(LinearEyeDepth(rawDepthC, _ZBufferParams), 0.001) * 0.05;

                //±3 = 7抽头二项式 (1,6,15,20,15,6,1)/64（就是"7×7拆成7+7"里的那趟7）
                static const float kernel[7] = { 0.015625, 0.09375, 0.234375, 0.3125, 0.234375, 0.09375, 0.015625 };

                float sum = 0.0;
                float weightSum = 0.0;
                [unroll]
                for (int i = -3; i <= 3; i++)
                {
                    float2 uvN = uv + float2(i * texelX, 0.0);
                    float w = kernel[i + 3] * BilateralWeight(uvN, posC, normalC, depthTolerance);
                    sum += w * SAMPLE_TEXTURE2D_LOD(_ScreenSpaceShadowTex, sampler_linear_clamp, uvN, 0).r;
                    weightSum += w;
                }
                //注意：加权之后要除以"权重和"，不是除以采样次数，否则边缘会整体变亮/变暗
                return sum / max(weightSum, 1e-4);
            }
            ENDHLSL
        }

        //3.纵向模糊：_ScreenSpaceShadowTex_TempBlur → _ScreenSpaceShadowTex
        //   （和横向那趟完全对称，只是取y方向的邻居；两趟转一圈回来，结果仍在 _ScreenSpaceShadowTex 里）
        Pass
        {
            Name "Blur Vertical"

            HLSLPROGRAM
            #pragma target 3.5

            TEXTURE2D(_ScreenSpaceShadowTex_TempBlur);

            #pragma vertex DefaultPassVertex
            #pragma fragment BlurVerticalPassFragment

            float BlurVerticalPassFragment(Varyings input) : SV_Target
            {
                float2 uv = input.screenUV;
                //这张图自己的纹素尺寸（半分辨率 ⇒ 是屏幕纹素的2倍），纵向取y
                float texelY = _ScreenSpaceShadowResultTexelSize.y;

                float rawDepthC = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
                if (rawDepthC < 1e-5)
                {
                    return 1.0;//天空：pass0写进去的就是1
                }

                float3 posC = ScreenSpaceWorldPosFromDepth(uv, rawDepthC);
                float3 normalC = ScreenSpaceSceneNormal(uv);
                float depthTolerance = max(LinearEyeDepth(rawDepthC, _ZBufferParams), 0.001) * 0.05;

                //±3 = 7抽头二项式 (1,6,15,20,15,6,1)/64，纵向（和横向完全对称）
                static const float kernel[7] = { 0.015625, 0.09375, 0.234375, 0.3125, 0.234375, 0.09375, 0.015625 };

                float sum = 0.0;
                float weightSum = 0.0;
                [unroll]
                for (int i = -3; i <= 3; i++)
                {
                    float2 uvN = uv + float2(0.0, i * texelY);
                    float w = kernel[i + 3] * BilateralWeight(uvN, posC, normalC, depthTolerance);
                    sum += w * SAMPLE_TEXTURE2D_LOD(_ScreenSpaceShadowTex_TempBlur, sampler_linear_clamp, uvN, 0).r;
                    weightSum += w;
                }
                return sum / max(weightSum, 1e-4);
            }
            ENDHLSL
        }

        //=========================================================
        //====== 以下三趟是"半影mask"那套（akg/原神）：先分区域，只在半影带里跑PCSS ======
        //为什么追加在文件末尾：C# 是按**索引**调用 pass 的（DrawProcedural 的 pass 号），
        //插在上面三个 Pass 中间会让它们的索引全部错位；真正决定流程的是 C# 里的绘制顺序。
        //=========================================================

        //4.半影mask：1/4分辨率 —— 一个纹素对应4×4个屏幕像素。
        //  判定三步（细节和理由见 Shadows.hlsl 的 EstimateShadowBandValue）：
        //   ① 迷你 blocker search：一处遮挡都没有 ⇒ 直接 1（受光）
        //   ② 估出"本地实际半影宽度"，细于阈值(MASK_BAND_MIN_TEXELS个mask纹素) ⇒ 直接二值
        //   ③ 拿这个宽度当半径做"边界探测"：中心和邻居明暗全一致 ⇒ 不在半影里 ⇒ 直接二值
        //      有不一致 ⇒ 边界就在一个半影宽度之内 ⇒ 写 0.5（交给PCSS）
        //  0 = 全遮、1 = 全亮、0.5 = 半影带。
        Pass
        {
            Name "Penumbra Mask"

            HLSLPROGRAM
            #pragma target 3.5
            //这一趟不需要任何阴影关键字：它只做"采一次深度图 + 一次比较"，和滤波档位/PCSS开关无关

            #pragma vertex DefaultPassVertex
            #pragma fragment PenumbraMaskPassFragment

            //一个mask纹素 → 0(全遮) / 1(全亮) / 0.5(半影带，交给PCSS)
            float PenumbraMaskAt (float2 uv)
            {
                float rawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);

                //先**无条件**重建世界坐标并算屏幕导数：ddx/ddy 是象限级的，
                //要是有些lane提前return（天空），同一象限里其它lane的导数就会被带歪。
                //⚠️ max(rawDepth,1e-5)：天空(depth=0)时 w=0 ⇒ 世界坐标会变 inf，导数跟着坏
                float3 posWS = ScreenSpaceWorldPosFromDepth(uv, max(rawDepth, 1e-5));
                //一个mask纹素**在世界里**有多长（mask纹素 = 4个屏幕像素）→ 判据要用
                float worldPerMaskTexel = max(length(ddx(posWS)), length(ddy(posWS)));

                if (rawDepth < 0.00001 || GetDirectionalLightCount() == 0)
                {
                    return 1.0;//背景/没有实时光：算受光
                }

                Surface surfaceWS;
                surfaceWS.position = posWS;
                surfaceWS.depth = -TransformWorldToView(surfaceWS.position).z;
                float3 normal = ScreenSpaceSceneNormal(uv);//延迟读GBuffer2，前向读_CameraNormalsTexture
                surfaceWS.normal = normal;
                //PCSS 的 bias 法线要"几何面法线"（不含法线图扰动）：和延迟光照 pass 同一个函数、同一口径
                surfaceWS.interpolatedNormal = ScreenSpaceGeometricNormal(surfaceWS.position, surfaceWS.depth, normal, uv);
                surfaceWS.viewDirection = normalize(_WorldSpaceCameraPos - surfaceWS.position);
                surfaceWS.dither = 0.0;//这一趟不做级联混合，抖动给0即可（行为确定）
                surfaceWS.albedo = 0.0;
                surfaceWS.alpha = 1.0;
                surfaceWS.roughness = 0.0;
                surfaceWS.metallic = 0.0;
                surfaceWS.occlusion = 1.0;
                surfaceWS.renderingLayerMask = 0;

                ShadowData shadowData = GetShadowData(surfaceWS);
                DirectionalShadowData directional = GetDirectionalShadowData(0, shadowData);//主光=第一个定向光
                if (directional.strength * shadowData.strength <= 0.0)
                {
                    return 1.0;//实时阴影不可用（超出最后一个级联、或该光没有阴影强度）
                }
                return EstimateShadowBandValue(surfaceWS, shadowData, directional, worldPerMaskTexel);
            }

            float PenumbraMaskPassFragment (Varyings input) : SV_Target
            {
                return PenumbraMaskAt(input.screenUV);
            }
            ENDHLSL
        }

        //5.横向模糊mask：_ScreenSpaceShadowMaskTex → _ScreenSpaceShadowMaskTexTemp
        //  ① 纯箱式平均，**不用双边**：这一趟的目的不是给噪声去噪，而是把半影带**故意扩宽**，
        //    让带子比真实的半影更宽一点（宁宽勿窄：窄了就会出现"该软的地方是硬的"）。
        //    双边权重恰恰会压住"跨物体边界"的混合，而阴影边界就在物体接触处 → 帮倒忙；
        //    而且双边每个抽头要读深度+法线+重建世界坐标（3次采样），箱式只要1次。
        //  ② 半径随距离放大（akg那个奇技淫巧）：mask是屏幕空间下采样的，物体离得越近、
        //    它真实的半影在屏幕上越大，固定半径做不到 → 用 1/(d²·k+k) 的系数补偿。
        Pass
        {
            Name "Mask Blur Horizontal"

            HLSLPROGRAM
            #pragma target 3.5

            #pragma vertex DefaultPassVertex
            #pragma fragment MaskBlurHorizontalPassFragment

            float MaskBlurHorizontalPassFragment (Varyings input) : SV_Target
            {
                float2 uv = input.screenUV;
                //mask自己的一个纹素（= 屏幕纹素的4倍）
                float texelX = _ScreenSpaceShadowTexelSize.x;

                //抽头间距（= radius 个mask纹素）。默认1 = 普通箱式；距离补偿默认关，见上面 define 的注释
                float radius = 1.0;
                #if MASK_BLUR_DISTANCE_COMPENSATION
                float rawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
                if (rawDepth >= 1e-5)
                {
                    float3 posWS = ScreenSpaceWorldPosFromDepth(uv, rawDepth);
                    float dis = distance(_WorldSpaceCameraPos.xyz, posWS);
                    radius = 1.0 / (dis * dis * MASK_BLUR_FALLOFF + MASK_BLUR_FALLOFF);
                }
                radius = clamp(radius, MASK_BLUR_RADIUS_MIN, MASK_BLUR_RADIUS_MAX);
                #endif

                float sum = 0.0;
                [unroll]
                for (int i = -MASK_BLUR_RADIUS; i <= MASK_BLUR_RADIUS; i++)
                {
                    float2 uvN = uv + float2(i * texelX, 0.0) * radius;
                    sum += SAMPLE_TEXTURE2D_LOD(_ScreenSpaceShadowMaskTex, sampler_linear_clamp, uvN, 0).r;
                }
                return sum / (2.0 * MASK_BLUR_RADIUS + 1.0);
            }
            ENDHLSL
        }

        //6.纵向模糊mask：_ScreenSpaceShadowMaskTexTemp → _ScreenSpaceShadowMaskTex
        //  （和横向那趟完全对称，只是取y方向的邻居；两趟转一圈，结果仍在mask自己身上）
        Pass
        {
            Name "Mask Blur Vertical"

            HLSLPROGRAM
            #pragma target 3.5

            TEXTURE2D(_ScreenSpaceShadowMaskTexTemp);

            #pragma vertex DefaultPassVertex
            #pragma fragment MaskBlurVerticalPassFragment

            float MaskBlurVerticalPassFragment (Varyings input) : SV_Target
            {
                float2 uv = input.screenUV;
                float texelY = _ScreenSpaceShadowTexelSize.y;

                //抽头间距（= radius 个mask纹素）。默认1 = 普通箱式；距离补偿默认关，见上面 define 的注释
                float radius = 1.0;
                #if MASK_BLUR_DISTANCE_COMPENSATION
                float rawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
                if (rawDepth >= 1e-5)
                {
                    float3 posWS = ScreenSpaceWorldPosFromDepth(uv, rawDepth);
                    float dis = distance(_WorldSpaceCameraPos.xyz, posWS);
                    radius = 1.0 / (dis * dis * MASK_BLUR_FALLOFF + MASK_BLUR_FALLOFF);
                }
                radius = clamp(radius, MASK_BLUR_RADIUS_MIN, MASK_BLUR_RADIUS_MAX);
                #endif

                float sum = 0.0;
                [unroll]
                for (int i = -MASK_BLUR_RADIUS; i <= MASK_BLUR_RADIUS; i++)
                {
                    float2 uvN = uv + float2(0.0, i * texelY) * radius;
                    sum += SAMPLE_TEXTURE2D_LOD(_ScreenSpaceShadowMaskTexTemp, sampler_linear_clamp, uvN, 0).r;
                }
                return sum / (2.0 * MASK_BLUR_RADIUS + 1.0);
            }
            ENDHLSL
        }
    }
}
