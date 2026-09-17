#ifndef CUSTOM_LIT_PASS_INCLUDED
#define CUSTOM_LIT_PASS_INCLUDED

#include "../ShaderLibrary/Surface.hlsl"
#include "../ShaderLibrary/Shadows.hlsl"
#include "../ShaderLibrary/Light.hlsl"
#include "../ShaderLibrary/BRDF.hlsl"
#include "../ShaderLibrary/GI.hlsl"
#include "../ShaderLibrary/Lighting.hlsl"

struct Attributes {
    float3 positionOS : POSITION;
    float3 normalOS : NORMAL;
    float4 tangentOS : TANGENT;
    float2 baseUV : TEXCOORD0;
    GI_ATTRIBUTE_DATA
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct Varyings
{
    float4 positionCS_SS : SV_POSITION;
    float3 positionWS : VAR_POSITION;
    float3 normalWS : VAR_NORMAL;
    #if defined(_NORMAL_MAP)
        float4 tangentWS : VAR_TANGENT;
    #endif
    float2 baseUV : VAR_BASE_UV;
    #if defined(_DETAIL_MAP)
        float2 detailUV : VAR_DETAIL_UV;
    #endif
    GI_VARYINGS_DATA
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

Varyings LitPassVertex(Attributes input)// : SV_Position
{
    Varyings output;
    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_TRANSFER_INSTANCE_ID(input, output);
    TRANSFER_GI_DATA(input, output);
    output.positionWS = TransformObjectToWorld(input.positionOS);
    output.positionCS_SS = TransformWorldToHClip(output.positionWS);
    output.normalWS = TransformObjectToWorldNormal(input.normalOS);
    #if defined(_NORMAL_MAP)
        output.tangentWS = float4(TransformObjectToWorldDir(input.tangentOS.xyz), input.tangentOS.w);
    #endif
    output.baseUV = TransformBaseUV(input.baseUV);
    #if defined(_DETAIL_MAP)
        output.detailUV = TransformDetailUV(input.baseUV);
    #endif
    return output;
}

float4 LitPassFragment(Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);
    
    InputConfig config = GetInputConfig(input.positionCS_SS, input.baseUV);
    ClipLOD(config.fragment, unity_LODFade.x);
    #if defined(_DETAIL_MAP)
        config.detailUV = input.detailUV;
    #endif
    
    float4 base = GetBase(config);
    
    #if defined(_CLIPPING)
        clip(base.a - GetCutoff(config));
    #endif
    
    Surface surface;
    surface.position = input.positionWS;
    #if defined(_NORMAL_MAP)
        surface.normal = normalize(NormalTangentToWorld(GetNormalTS(config), input.normalWS, input.tangentWS));
        surface.interpolatedNormal = normalize(input.normalWS);
    #else
        surface.normal = normalize(input.normalWS);
        surface.interpolatedNormal = surface.normal;
    #endif
    surface.viewDirection = normalize(_WorldSpaceCameraPos - input.positionWS);
    surface.depth = - TransformWorldToView(input.positionWS).z;
    surface.albedo = base.rgb;
    surface.alpha = base.a;
    surface.metallic = GetMetallic(config);
    surface.occlusion = GetOcclusion(config);
    surface.roughness = GetRoughness(config);
    //surface.fresnelStrength = GetFresnel(config);
    surface.dither = InterleavedGradientNoise(config.fragment.positionSS, 0);
    surface.renderingLayerMask = asuint(unity_RenderingLayer.x);
    
    #if defined(_PREMULTIPLY_ALPHA)
        BRDF brdf = GetBRDF(surface, true);
    #else
        BRDF brdf = GetBRDF(surface, false);
    #endif
    
    //（gi.specular 由 GetGI 一次算好：环境反射与**上一帧**的SSR按可信度a混好 —— 物体在"拷颜色快照+追SSR"
    //  之前就画完了，所以只能拿上一帧的；Fresnel/F0 那套权重在 IndirectBRDF 里统一乘，别在外面再乘）
    GI gi = GetGI(GI_FRAGMENT_DATA(input), surface, brdf, config.fragment.screenUV);
    float3 color = GetLightingForward(surface, brdf, gi);
    color += GetEmission(config);
    
    //有一些比较幽默的事情，关于纹理和采样器混用，造成的“采样器未声明”的报错
    //例如SAMPLE_TEXTURE2D(_MaskMap, sampler_BaseMap, input.baseUV);混用了Mask贴图和基础纹理，直接输出就会报错，说"uncognized sampler(sampler_basemap)"
    //但是，如果在一次调用中，同时还正确的用了这个sampler及sampler对应的纹理，就不会如此报错，如SAMPLE_TEXTURE2D(_MaskMap, sampler_BaseMap, input.baseUV) * SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, config.baseUV);
    //编译器不查混用，只查“孤儿”
    //所以这也就是，你现在不启用_MASK_MAP的时候，单独输出GetSmoothness就会报错的原因
    
    
    return float4(color, GetFinalAlpha(surface.alpha));//不透明物体强制Alpha=1，保证相机叠加时Alpha值正确
}

//Lit ShadingModelID = 1
//针对Opaque Lit物体，把数据写入GBuffer的多张GT中，等待CameraRenderer的"Deferred Lighting" pass计算光照
void LitPassFragmentGBuffer(Varyings input,
    out float4 GT1 : SV_Target0,
    out float4 GT2 : SV_Target1,
    out float4 GT3 : SV_Target2,
    out float3 GT4 : SV_Target3)
{
    UNITY_SETUP_INSTANCE_ID(input);
    
    InputConfig config = GetInputConfig(input.positionCS_SS, input.baseUV);
    ClipLOD(config.fragment, unity_LODFade.x);
    #if defined(_DETAIL_MAP)
        config.detailUV = input.detailUV;
    #endif
    
    float4 base = GetBase(config);
    float3 color = base.rgb;
    
    #if defined(_CLIPPING)
        clip(base.a - GetCutoff(config));
    #endif
    
    Surface surfaceWS;
    surfaceWS.position = input.positionWS;
    #if defined(_NORMAL_MAP)
        surfaceWS.normal = normalize(NormalTangentToWorld(GetNormalTS(config), input.normalWS, input.tangentWS));
        surfaceWS.interpolatedNormal = normalize(input.normalWS);
    #else
        surfaceWS.normal = normalize(input.normalWS);
        surfaceWS.interpolatedNormal = surfaceWS.normal;
    #endif
    surfaceWS.viewDirection = normalize(_WorldSpaceCameraPos - input.positionWS);
    surfaceWS.depth = - TransformWorldToView(input.positionWS).z;
    surfaceWS.albedo = base.rgb;
    surfaceWS.alpha = 1;
    surfaceWS.metallic = GetMetallic(config);
    surfaceWS.occlusion = GetOcclusion(config);
    surfaceWS.roughness = GetRoughness(config);
    surfaceWS.dither = InterleavedGradientNoise(config.fragment.positionSS, 0);
    surfaceWS.renderingLayerMask = asuint(unity_RenderingLayer.x);
    
    BRDF brdf = GetBRDF(surfaceWS, false);
    
    //（gi.specular 由 GetGI 一次算好：这一趟是**逐物体**绘制 ⇒ 环境反射(Cube)和上一帧的SSR图都拿得到；
    //  全屏pass里读不到逐物体的 unity_SpecCube0/HDR，这也是当初拆出"合成pass"的原因，现在不需要了）
    GI gi = GetGI(GI_FRAGMENT_DATA(input), surfaceWS, brdf, config.fragment.screenUV);
    
    float3 emission = GetEmission(config);
    
    //间接光（漫反射 + 高光）整包写进 GT4，光照Pass整体加上去就完事
    float3 indirectColor = IndirectBRDF(surfaceWS, brdf, gi.diffuse, gi.specular);
        //SampleLightmap(GI_FRAGMENT_DATA(input)) + SampleLightProbe(input.positionWS, normalWS);
    
    float shadingModelID4_null4 = ((uint)1 << 4)/255.0;
    GT1 = float4(color, shadingModelID4_null4);
    GT2 = float4(surfaceWS.normal * 0.5 + 0.5, 0.0);
    GT3 = float4(surfaceWS.roughness, surfaceWS.metallic, surfaceWS.occlusion, 0.0);
    GT4 = float3(emission + indirectColor);
    
    
    //GT5 = float4(indirectDiffuse, 0);
    //return float4(color, GetFinalAlpha(surface.alpha));//不透明物体强制Alpha=1，保证相机叠加时Alpha值正确
}

#endif
