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
    float4 positionCS : SV_POSITION;
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
    output.positionCS = TransformWorldToHClip(output.positionWS);
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
    
    ClipLOD(input.positionCS.xy, unity_LODFade.x);
    
    InputConfig config = GetInputConfig(input.baseUV);
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
    surface.dither = InterleavedGradientNoise(input.positionCS.xy, 0);
    
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
    
    return float4(color, surface.alpha);
}

#endif
