//为了避免多次包含同一文件，产生重复的代码，添加一个包含保护
#ifndef CUSTOM_UNLITTRANSPARENT_PASS_INCLUDED//如果没包含，就去define
#define CUSTOM_UNLITTRANSPARENT_PASS_INCLUDED

struct Attributes {
    float3 positionOS : POSITION;
    float2 baseUV : TEXCOORD0;
    UNITY_VERTEX_INPUT_INSTANCE_ID//用于GPU实例化的对象索引，for vertex
};

struct Varyings
{
    float4 positionCS_SS : SV_POSITION;
    float2 baseUV : VAR_BASE_UV;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

Varyings UnlitTransparentPassVertex(Attributes input)// : SV_Position
{
    Varyings output;
    UNITY_SETUP_INSTANCE_ID(input);//使索引可用
    UNITY_TRANSFER_INSTANCE_ID(input, output);//索引传到frag
    float3 positionWS = TransformObjectToWorld(input.positionOS);
    output.positionCS_SS = TransformWorldToHClip(positionWS);
    output.baseUV = TransformBaseUV(input.baseUV);
    return output;
}

float4 UnlitTransparentPassFragment(Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);//frag里，使索引可用
    
    InputConfig config = GetInputConfig(input.positionCS_SS, input.baseUV);
    float4 base = GetBase(config);
    
    #if defined(_CLIPPING)
        clip(base.a - GetCutoff(config));
    #endif
    return base;
}

#endif//如果包含了，就跳过
