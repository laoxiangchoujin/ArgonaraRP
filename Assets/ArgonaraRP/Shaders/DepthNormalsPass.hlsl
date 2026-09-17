#ifndef CUSTOM_DEPTH_NORMALS_PASS_INCLUDED
#define CUSTOM_DEPTH_NORMALS_PASS_INCLUDED

//深度法线prepass（屏幕空间阴影/SSAO等要用）：这个文件只管fragment，深度由 ZWrite On 自动写进深度附件，
//法线输出到绑定的那张法线图（前向叫 _CameraNormalsTexture）里。
//
//和 ShadowCasterPass.hlsl 一样：本文件不自己 include，依赖调用方先 include LitPass.hlsl
//（提供 Varyings / LitPassVertex / InputConfig 等），这样 Lit.shader 和 GPUDrivenTerrain.shader
//各自的相对路径都能用。
//
//写的是**前向的着色法线**（= LitPassFragment 里那条：算法线贴图得到的世界空间法线），
//编码 "normal * 0.5 + 0.5"，和延迟那边的 _GBuffer2 **完全同一口径** ⇒ 两条路共享的屏幕空间效果
//（SSR 的接收面反射方向、PCSS 两趟 blur 的保边项、给几何法线重构当翻正参考）读到的是同一种东西。
//⚠️ 阴影 bias 要的**几何法线**不在这里：全屏 pass 用 ScreenSpaceGeometricNormal（见 Fragment.hlsl）从深度重构。
float4 DepthNormalsPassFragment (Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);

    InputConfig config = GetInputConfig(input.positionCS_SS, input.baseUV);
    ClipLOD(config.fragment, unity_LODFade.x);

    #if defined(_CLIPPING)
        clip(GetBase(config).a - GetCutoff(config));
    #endif

    //和 LitPassFragment 同一条算法（法线贴图 → 世界空间着色法线），只是不做光照
    #if defined(_NORMAL_MAP)
        float3 normalWS = normalize(NormalTangentToWorld(GetNormalTS(config), input.normalWS, input.tangentWS));
    #else
        float3 normalWS = normalize(input.normalWS);
    #endif

    //法线编码成 0~1 存（和 GBuffer2 一样的约定），省得两边解码方式不同
    return float4(normalWS * 0.5 + 0.5, 0.0);
}

#endif
