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
    float2 baseUV : TEXCOORD0;
    GI_ATTRIBUTE_DATA
    UNITY_VERTEX_INPUT_INSTANCE_ID//用于GPU实例化的对象索引，for vertex
};

struct Varyings
{
    float4 positionCS : SV_POSITION;
    float3 positionWS : VAR_POSITION;
    float3 normalWS : VAR_NORMAL;
    float2 baseUV : VAR_BASE_UV;
    GI_VARYINGS_DATA
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

Varyings LitPassVertex(Attributes input)// : SV_Position
{
    Varyings output;
    UNITY_SETUP_INSTANCE_ID(input);//使索引可用
    UNITY_TRANSFER_INSTANCE_ID(input, output);//索引传到frag
    TRANSFER_GI_DATA(input, output);
    output.positionWS = TransformObjectToWorld(input.positionOS);
    output.positionCS = TransformWorldToHClip(output.positionWS);
    output.normalWS = TransformObjectToWorldNormal(input.normalOS);
    output.baseUV = TransformBaseUV(input.baseUV);
    return output;
}

float4 LitPassFragment(Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);//frag里，使索引可用
    
    // #if defined(LOD_FADE_CROSSFADE)
    // return unity_LODFade.x;
    // #endif
    ClipLOD(input.positionCS.xy, unity_LODFade.x);
    
    // float4 baseMap = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.baseUV);
    // float4 baseColor = UNITY_ACCESS_INSTANCED_PROP(UnityPerMaterial, _BaseColor);
    // float4 base = baseMap * baseColor;
    float4 base = GetBase(input.baseUV);
    
    #if defined(_CLIPPING)
        clip(base.a - GetCutoff(input.baseUV));
    #endif
    
    Surface surface;
    surface.position = input.positionWS;
    surface.normal = normalize(input.normalWS);//跨三角形的线性插值会影响法线向量的长度，为了让法线都是单位长度，一定要这么干
    surface.viewDirection = normalize(_WorldSpaceCameraPos - input.positionWS);
    surface.depth = - TransformWorldToView(input.positionWS).z;
    surface.color = base.rgb;
    surface.alpha = base.a;
    surface.metallic = GetMetallic(input.baseUV);
    surface.smoothness = GetSmoothness(input.baseUV);
    surface.fresnelStrength = GetFresnel(input.baseUV);
    surface.dither = InterleavedGradientNoise(input.positionCS.xy, 0);//Core库的生成抖动的函数，第二个参数是动画，不用
    
    #if defined(_PREMULTIPLY_ALPHA)
        BRDF brdf = GetBRDF(surface, true);
    #else
        BRDF brdf = GetBRDF(surface, false);//这个函数确实有俩参数，但后边的已有默认值false，所以可以不传
    #endif
    
    GI gi = GetGI(GI_FRAGMENT_DATA(input), surface, brdf);
    float3 color = GetLighting(surface, brdf, gi);
    color += GetEmission(input.baseUV);
    return float4(color, surface.alpha);
    //return float4(surface.color, surface.alpha);//必须如此，用id获取实例化属性数组里的属性
}

#endif