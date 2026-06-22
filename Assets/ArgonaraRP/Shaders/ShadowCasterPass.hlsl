#ifndef CUSTOM_SHADOW_CASTER_PASS_INCLUDED
#define CUSTOM_SHADOW_CASTER_PASS_INCLUDED

struct Attributes {
    float3 positionOS : POSITION;
    float2 baseUV : TEXCOORD0;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct Varyings
{
    float4 positionCS : SV_POSITION;
    float2 baseUV : VAR_BASE_UV;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

bool _ShadowPancaking;

Varyings ShadowCasterPassVertex(Attributes input)// : SV_Position
{
    Varyings output;
    UNITY_SETUP_INSTANCE_ID(input);//使索引可用
    UNITY_TRANSFER_INSTANCE_ID(input, output);//索引传到frag
    float3 positionWS = TransformObjectToWorld(input.positionOS);
    output.positionCS = TransformWorldToHClip(positionWS);
    
    if (_ShadowPancaking)//用全局bool区分，透视投影的shadow caster不用这个
    {
        //不太清楚是什么代码在哪做的，但是在渲染定向光的shadow caster的时候，会把近裁剪平面朝靠近shadow caster的方向移动
        //是为了增加深度精度，但是，对于不在相机视野内的物体，可能已经在近平面后边了，被错误的裁剪掉了
        //把它HCS的顶点摊平，统一压到不会在近平面后边，这叫shadow pancaking阴影摊平
        #if UNITY_REVERSED_Z
        output.positionCS.z = min(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
        #else
        output.positionCS.z =max(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);//opengl没reverse z，1表示深度大，只要深度比near更大就行
        #endif
        //↑上边的方法，适用于"完全在近平面前边/完全在它后边的几何"
        //对于一个跨越了近平面的三角形，例如俩顶点在near前，一个在near后，这样做就会导致这个三角形投射的阴影变形，尤其是很大的如此的三角形，那会很明显
    }
        
    output.baseUV = TransformBaseUV(input.baseUV);
    return output;
}

void ShadowCasterPassFragment(Varyings input)
{
    UNITY_SETUP_INSTANCE_ID(input);//frag里，使索引可用
    
    ClipLOD(input.positionCS.xy, unity_LODFade.x);
    
    InputConfig config = GetInputConfig(input.baseUV);
    float4 base = GetBase(config);
    
    #if defined(_SHADOWS_CLIP)
        clip(base.a - GetCutoff(config));
        #elif defined(_SHADOWS_DITHER)
            float dither = InterleavedGradientNoise(input.positionCS.xy, 0);
            clip(base.a - dither);
    #endif
}

#endif
