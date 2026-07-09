//为了避免多次包含同一文件，产生重复的代码，添加一个包含保护
#ifndef CUSTOM_UNLIT_PASS_INCLUDED//如果没包含，就去define
#define CUSTOM_UNLIT_PASS_INCLUDED

struct Attributes {
    float3 positionOS : POSITION;
    float2 baseUV : TEXCOORD0;
    UNITY_VERTEX_INPUT_INSTANCE_ID//用于GPU实例化的对象索引，for vertex
};

struct Varyings
{
    float4 positionCS : SV_POSITION;
    float2 baseUV : VAR_BASE_UV;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

Varyings UnlitPassVertex(Attributes input)// : SV_Position
{
    Varyings output;
    UNITY_SETUP_INSTANCE_ID(input);//使索引可用
    UNITY_TRANSFER_INSTANCE_ID(input, output);//索引传到frag
    float3 positionWS = TransformObjectToWorld(input.positionOS);
    output.positionCS = TransformWorldToHClip(positionWS);
    output.baseUV = TransformBaseUV(input.baseUV);
    return output;
}

float4 UnlitPassFragment(Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);//frag里，使索引可用
    
    InputConfig config = GetInputConfig(input.baseUV);
    float4 base = GetBase(config);
    
    #if defined(_CLIPPING)
        clip(base.a - GetCutoff(config));
    #endif
    
    base.rgb += GetEmission(config);
    return float4(base.rgb, GetFinalAlpha(base.a));//不透明物体强制Alpha=1，保证相机叠加时Alpha值正确
}

#endif//如果包含了，就跳过
