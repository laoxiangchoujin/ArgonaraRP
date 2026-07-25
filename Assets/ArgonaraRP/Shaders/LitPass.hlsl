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
    #if defined(_MASK_MAP)
        config.useMask = true;
    #endif
    #if defined(_DETAIL_MAP)
    config.detailUV = input.detailUV;
    config.useDetail = true;
    #endif
    
    float4 base = GetBase(config);
    
    #if defined(_CLIPPING)
        clip(base.a - GetCutoff(config));
    #endif
    
    Surface surface;
    surface.position = input.positionWS;
    #if defined(_NORMAL_MAP)
        surface.normal = NormalTangentToWorld(GetNormalTS(config), input.normalWS, input.tangentWS);
        surface.interpolatedNormal = normalize(input.normalWS);
    #else
        surface.normal = normalize(input.normalWS);
        surface.interpolatedNormal = surface.normal;
    #endif
    surface.viewDirection = normalize(_WorldSpaceCameraPos - input.positionWS);
    surface.depth = - TransformWorldToView(input.positionWS).z;
    surface.color = base.rgb;
    surface.alpha = base.a;
    surface.metallic = GetMetallic(config);
    surface.occlusion = GetOcclusion(config);
    surface.smoothness = GetSmoothness(config);
    surface.fresnelStrength = GetFresnel(config);
    surface.dither = InterleavedGradientNoise(config.fragment.positionSS, 0);
    surface.renderingLayerMask = asuint(unity_RenderingLayer.x);
    
    #if defined(_PREMULTIPLY_ALPHA)
        BRDF brdf = GetBRDF(surface, true);
    #else
        BRDF brdf = GetBRDF(surface, false);
    #endif
    
    GI gi = GetGI(GI_FRAGMENT_DATA(input), surface, brdf);
    float3 color = GetLighting(surface, brdf, gi);
    color += GetEmission(config);
    
    //有一些比较幽默的事情，关于纹理和采样器混用，造成的“采样器未声明”的报错
    //例如SAMPLE_TEXTURE2D(_MaskMap, sampler_BaseMap, input.baseUV);混用了Mask贴图和基础纹理，直接输出就会报错，说"uncognized sampler(sampler_basemap)"
    //但是，如果在一次调用中，同时还正确的用了这个sampler及sampler对应的纹理，就不会如此报错，如SAMPLE_TEXTURE2D(_MaskMap, sampler_BaseMap, input.baseUV) * SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, config.baseUV);
    //编译器不查混用，只查“孤儿”
    //所以这也就是，你现在不启用_MASK_MAP的时候，单独输出GetSmoothness就会报错的原因
   
    //return GetSmoothness(config);
    //return float4(gi.diffuse,1);
    //return float4(GetLighting(surface, brdf, gi),1.0);
    //return float4(config.fragment.screenUV, 0.0, 1.0);
     //return float4(input.positionWS.xyz * 0.1, 1.0);  // 世界坐标×缩放显示
    //
     //return float4(surface.viewDirection, 1.0);
     //return float4(gi.specular, 1.0);
    
    return float4(color, GetFinalAlpha(surface.alpha));//不透明物体强制Alpha=1，保证相机叠加时Alpha值正确
}

//针对Opaque Lit物体，把数据写入GBuffer的多张GT中，等待CameraRenderer的"Deferred Lighting" pass计算光照
void LitPassFragmentGBuffer(Varyings input,
    out float4 GT1 : SV_Target0,
    out float4 GT2 : SV_Target1,
    out float4 GT3 : SV_Target2,
    out float4 GT4 : SV_Target3,
    out float4 GT5 : SV_Target4)
{
    UNITY_SETUP_INSTANCE_ID(input);
    
    InputConfig config = GetInputConfig(input.positionCS_SS, input.baseUV);
    ClipLOD(config.fragment, unity_LODFade.x);
    #if defined(_MASK_MAP)
        config.useMask = true;
    #endif
    #if defined(_DETAIL_MAP)
    config.detailUV = input.detailUV;
    config.useDetail = true;
    #endif
    
    float4 base = GetBase(config);
    float3 color = base.rgb;
    
    #if defined(_CLIPPING)
        clip(base.a - GetCutoff(config));
    #endif
    
    //Surface surface;
    //surface.position = input.positionWS;
    #if defined(_NORMAL_MAP)
        float3 normalWS = NormalTangentToWorld(GetNormalTS(config), input.normalWS, input.tangentWS);
    #else
        float3 normalWS = normalize(input.normalWS);
    #endif
    //surface.viewDirection = normalize(_WorldSpaceCameraPos - input.positionWS);
    //surface.depth = - TransformWorldToView(input.positionWS).z;
    
    //surface.alpha = base.a;
    float metallic = GetMetallic(config);
    float occlusion = GetOcclusion(config);
    float smoothness = GetSmoothness(config);
    //surface.fresnelStrength = GetFresnel(config);
    //surface.dither = InterleavedGradientNoise(config.fragment.positionSS, 0);
    //surface.renderingLayerMask = asuint(unity_RenderingLayer.x);
    
    float3 emission = GetEmission(config);
    
    float3 indirectDiffuse = SampleLightmap(GI_FRAGMENT_DATA(input)) + SampleLightProbe(input.positionWS, normalWS);
    
    GT1 = float4(color, 1);
    GT2 = float4(normalWS * 0.5 + 0.5, 0);
    GT3 = float4(0,0,smoothness,metallic);
    GT4 = float4(emission,occlusion);
    
    
    GT5 = float4(indirectDiffuse, 0);
    //return float4(color, GetFinalAlpha(surface.alpha));//不透明物体强制Alpha=1，保证相机叠加时Alpha值正确
}

#endif
