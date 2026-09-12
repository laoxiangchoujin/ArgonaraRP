#ifndef CUSTOM_DEPTH_NORMALS_PASS_INCLUDED
#define CUSTOM_DEPTH_NORMALS_PASS_INCLUDED

//深度法线prepass（屏幕空间阴影/SSAO等要用）：这个文件只管fragment，深度由 ZWrite On 自动写进深度附件，
//法线输出到绑定的那张法线图（前向叫 _CameraNormalsTexture）里。
//
//和 ShadowCasterPass.hlsl 一样：本文件不自己 include，依赖调用方先 include LitPass.hlsl
//（提供 Varyings / LitPassVertex / InputConfig 等），这样 Lit.shader 和 GPUDrivenTerrain.shader
//各自的相对路径都能用。
//
//写的是**几何法线**（input.normalWS，不含法线贴图）：屏幕空间阴影的bias、SSAO 都用这把尺子，
//和延迟那边"GBuffer2存的是含法线贴图的法线"略有差别，但口径与 forward 的光照一致。
float4 DepthNormalsPassFragment (Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);

    InputConfig config = GetInputConfig(input.positionCS_SS, input.baseUV);
    ClipLOD(config.fragment, unity_LODFade.x);

    #if defined(_CLIPPING)
        clip(GetBase(config).a - GetCutoff(config));
    #endif

    //法线编码成 0~1 存（和 GBuffer2 一样的约定），省得两边解码方式不同
    return float4(normalize(input.normalWS) * 0.5 + 0.5, 0.0);
}

#endif
