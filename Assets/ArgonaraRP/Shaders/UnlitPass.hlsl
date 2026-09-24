//为了避免多次包含同一文件，产生重复的代码，添加一个包含保护
#ifndef CUSTOM_UNLIT_PASS_INCLUDED//如果没包含，就去define
#define CUSTOM_UNLIT_PASS_INCLUDED

struct Attributes {
    float3 positionOS : POSITION;
    float4 color : COLOR;//顶点色，粒子系统用于逐粒子颜色
    #if defined(_FLIPBOOK_BLENDING)
        float4 baseUV : TEXCOORD0;
        float flipbookBlend : TEXCOORD1;
    #else
        float2 baseUV : TEXCOORD0;
    #endif
    UNITY_VERTEX_INPUT_INSTANCE_ID//用于GPU实例化的对象索引，for vertex
};

struct Varyings
{
    float4 positionCS_SS : SV_POSITION;
    #if defined(_VERTEX_COLORS)
        float4 color : VAR_COLOR;
    #endif
    float2 baseUV : VAR_BASE_UV;
    #if defined(_FLIPBOOK_BLENDING)
        float3 flipbookUVB : VAR_FLIPBOOK;
    #endif
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

Varyings UnlitPassVertex(Attributes input)// : SV_Position
{
    Varyings output;
    UNITY_SETUP_INSTANCE_ID(input);//使索引可用
    UNITY_TRANSFER_INSTANCE_ID(input, output);//索引传到frag
    float3 positionWS = TransformObjectToWorld(input.positionOS);
    output.positionCS_SS = TransformWorldToHClip(positionWS);
    #if defined(_VERTEX_COLORS)
        output.color = input.color;
    #endif
    output.baseUV.xy = TransformBaseUV(input.baseUV.xy);
    #if defined(_FLIPBOOK_BLENDING)
        output.flipbookUVB.xy = TransformBaseUV(input.baseUV.zw);
        output.flipbookUVB.z = input.flipbookBlend;
    #endif
    return output;
}

float4 UnlitPassFragment(Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);//frag里，使索引可用
    
    InputConfig config = GetInputConfig(input.positionCS_SS, input.baseUV);
    //return GetBufferColor(config.fragment, 0.02);
    //return float4(config.fragment.bufferDepth.xxx / 20.0, 1.0);
    #if defined(_VERTEX_COLORS)
        config.color = input.color;
    #endif
    #if defined(_FLIPBOOK_BLENDING)
        config.flipbookUVB = input.flipbookUVB;
        config.flipbookBlending = true;
    #endif
    #if defined(_NEAR_FADE)
        config.nearFade = true;
    #endif
    #if defined(_SOFT_PARTICLES)
        config.softParticles = true;
    #endif
    
    float4 base = GetBase(config);
    
    #if defined(_CLIPPING)
        clip(base.a - GetCutoff(config));
    #endif
    #if defined(_DISTORTION)
        float2 distortion = GetDistortion(config) * base.a;
        base.rgb = lerp(GetBufferColor(config.fragment, distortion).rgb, base.rgb,
        saturate(base.a - GetDistortionBlend(config)));
    #endif
    
    base.rgb += GetEmission(config);
    return float4(base.rgb, GetFinalAlpha(base.a));//不透明物体强制Alpha=1，保证相机叠加时Alpha值正确
}

//Unlit ShadingModelID = 0
void UnlitPassFragmentGBuffer(Varyings input, 
    out float4 GT1 : SV_Target0,
    out float3 GT4 : SV_Target3,
    out float3 GT5 : SV_Target4)
{
    UNITY_SETUP_INSTANCE_ID(input);//frag里，使索引可用
    
    InputConfig config = GetInputConfig(input.positionCS_SS, input.baseUV);
    
    #if defined(_VERTEX_COLORS)
        config.color = input.color;
    #endif
    #if defined(_FLIPBOOK_BLENDING)
        config.flipbookUVB = input.flipbookUVB;
        config.flipbookBlending = true;
    #endif
    #if defined(_NEAR_FADE)
        config.nearFade = true;
    #endif
    #if defined(_SOFT_PARTICLES)
        config.softParticles = true;
    #endif
    
    float4 base = GetBase(config);
    
    #if defined(_CLIPPING)
        clip(base.a - GetCutoff(config));
    #endif
    #if defined(_DISTORTION)
        float2 distortion = GetDistortion(config) * base.a;
        base.rgb = lerp(GetBufferColor(config.fragment, distortion).rgb, base.rgb,
        saturate(base.a - GetDistortionBlend(config)));
    #endif
    
    float3 color = base.rgb;
    uint shadingModelID4_null4 = ((uint)0 << 4)/255.0;
    GT1 = float4(color, shadingModelID4_null4);
    //和 Lit 的 GBuffer pass 口径一致：GT4 = 间接光（unlit 没有，写 0）、GT5 = 自发光
    float3 emission = GetEmission(config);
    GT4 = 0.0;
    GT5 = float3(emission);
    // base.rgb += GetEmission(config);
    // return float4(base.rgb, GetFinalAlpha(base.a));//不透明物体强制Alpha=1，保证相机叠加时Alpha值正确
}

#endif//如果包含了，就跳过
