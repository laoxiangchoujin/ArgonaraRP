//为了避免多次包含同一文件，产生重复的代码，添加一个包含保护
#ifndef CUSTOM_UNLIT_PASS_INCLUDED//如果没包含，就去define
#define CUSTOM_UNLIT_PASS_INCLUDED

//为了减少draw call，要让shader兼容SRP batcher，第一，对材质，要把Material Properties放CBuffer里
//看到某个shader的面板，SRP Batcher为compatible，就ok了

// TEXTURE2D(_BaseMap);
// SAMPLER(sampler_BaseMap);

//对于GPU实例化，想做的事很可能是画100个颜色各不相同的球，而CBuffer里放的float4 _BaseColor就是一个固定的唯一的颜色，一个材质就只有一个颜色，这不合实例化的要求
//改用UNITY_INSTANCING_BUFFER，会让_BaseColor变成一个数组，像是float4 _BaseColor[100]，各实例有自己的颜色，正因此我们需要实例id


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
    //return UNITY_ACCESS_INSTANCED_PROP(UnityPerMaterial, _BaseColor);//必须如此，用id获取实例化属性数组里的属性
    
    float4 base = GetBase(input.baseUV);
    
    #if defined(_CLIPPING)
        clip(base.a - GetCutoff(input.baseUV));
    #endif
    
    base.rgb += GetEmission(input.baseUV);
    return base;
}

//emm，这个第二课的实例化，要知道srp batch是优先于实例化的，我们给一些物体用MPB改了参数，他们就不能做SRP bnatch了，会转而用GPU instancing来减少draw call

//关于float还是half，half当然效率更高，一般来说，float用于位置和纹理坐标，其他的用half算
//如果您要针对移动设备进行优化，那么尽可能多地使用 half 是有意义的,当不针对移动平台时，精度不是问题，因为 GPU 总是使用 float
//不做移动端，那我就不用half了，好


#endif//如果包含了，就跳过