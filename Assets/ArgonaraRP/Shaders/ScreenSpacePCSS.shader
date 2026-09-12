//第3步：屏幕空间 PCSS 阴影图
//把"逐像素几十次采样的 PCSS"从 Deferred Lighting 里挪出来，单独算一遍写成一张屏幕纹理，
//再用两趟 blur 去噪，最后光照 Pass 只采样一次这张纹理（还能顺带做半分辨率）。
//
//绘制顺序（都在 GBuffer 之后、Deferred Lighting 之前）：
//  GBuffer → 【本shader pass0 PCSS】→ 【pass1 横 blur】→ 【pass2 竖 blur】→ Deferred Lighting
//纹理：_ScreenSpaceShadowTex 存结果，_ScreenSpaceShadowTex_TempBlur 用来横竖两趟之间倒手
//（同一张纹理不能在同一次绘制里既读又写）。
//
//三个 Pass 都是由 CommandBuffer.DrawProcedural 手动绘制的（和 CameraRenderer.shader 一样），
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

        //屏幕空间阴影图自己的纹素尺寸：xy = 1/宽、1/高（zw = 宽、高），由 C# 按这张图的实际尺寸上传。
        //图是半分辨率的 ⇒ 它 = 屏幕纹素的2倍，所以blur取邻居必须用它，不能用 _CameraBufferSize
        float4 _ScreenSpaceShadowTexelSize;

        //屏幕UV + 原始深度 → 世界坐标（和 DeferredLightPassFragment 那套翻转保持一致）
        float3 ScreenSpaceBlurWorldPos (float2 uv, float rawDepth)
        {
            float4 posClip = float4(uv * 2 - 1, rawDepth, 1);
            #if UNITY_UV_STARTS_AT_TOP
                posClip.y = -posClip.y;
            #endif
            float4 posWS = mul(UNITY_MATRIX_I_VP, posClip);
            return posWS.xyz / posWS.w;
        }

        //本管线当前是前向还是延迟：1=延迟、0=前向（各自的渲染器每帧设置）。
        //用来区分"用途相同但名字不同"的纹理：延迟的法线在 _GBuffer2，前向的在 _CameraNormalsTexture（DepthNormals prepass输出）。
        int _UseDeferredRenderer;
        TEXTURE2D(_CameraNormalsTexture);

        //取当前场景的法线（几何法线）：延迟读GBuffer2，前向读DepthNormals prepass输出的法线图。
        //编码统一是 "normal * 0.5 + 0.5"，所以解码方式一样。
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
            float3 posN = ScreenSpaceBlurWorldPos(uvNeighbor, rawDepthN);
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

                //深度图重建世界坐标（抄 DeferredLightPassFragment）
                float4 posClip = float4(uv * 2 - 1, rawDepth, 1);
                #if UNITY_UV_STARTS_AT_TOP
                posClip.y = -posClip.y;  // 抵消 DefaultPassVertex 的 UV 翻转
                #endif
                float4 posWS = mul(UNITY_MATRIX_I_VP, posClip);
                posWS /= posWS.w;

                //伪造一个 Surface：阴影那套函数只要这几个字段（position/depth/dither/interpolatedNormal），
                //其余字段它们不读，给中立值即可（顺便省掉 GBuffer1/GBuffer3 的两次采样）
                Surface surfaceWS;
                surfaceWS.position = posWS.xyz;
                float3 normal = ScreenSpaceSceneNormal(uv);//延迟从GBuffer2、前向从_CameraNormalsTexture
                surfaceWS.normal = normal;
                surfaceWS.interpolatedNormal = normal;//主光PCSS的bias法线用它
                surfaceWS.viewDirection = normalize(_WorldSpaceCameraPos - surfaceWS.position);
                //视空间深度（米）：GetShadowData 里的距离淡出 FadedShadowStrength 要的是这个。
                //注意不能用原始深度值充当 depth（DeferredLightPassFragment 里那样写对距离淡出是错的）
                surfaceWS.depth = -TransformWorldToView(surfaceWS.position).z;
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
                float texelX = _ScreenSpaceShadowTexelSize.x;

                float rawDepthC = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
                if (rawDepthC < 1e-5)
                {
                    return 1.0;//天空：pass0写进去的就是1
                }

                float3 posC = ScreenSpaceBlurWorldPos(uv, rawDepthC);
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
                float texelY = _ScreenSpaceShadowTexelSize.y;

                float rawDepthC = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
                if (rawDepthC < 1e-5)
                {
                    return 1.0;//天空：pass0写进去的就是1
                }

                float3 posC = ScreenSpaceBlurWorldPos(uv, rawDepthC);
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
    }
}
