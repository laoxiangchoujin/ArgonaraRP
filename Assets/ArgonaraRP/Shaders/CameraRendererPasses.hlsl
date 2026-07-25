#ifndef CUSTOM_CAMERA_RENDERER_PASSES_INCLUDED
#define CUSTOM_CAMERA_RENDERER_PASSES_INCLUDED

TEXTURE2D(_SourceTexture);

TEXTURE2D(_GBuffer1);//rgb是albedo
TEXTURE2D(_GBuffer2);//rgb是world normal
TEXTURE2D(_GBuffer3);//rg是motion vector,ba是smoothness,metallic
TEXTURE2D(_GBuffer4);//rgb是emission,a是occlusion
TEXTURE2D(_GBuffer5);//xyz暂时存着indirect diffuse
//TEXTURE2D(_GBufferDepth);

struct Varyings
{
    float4 positionCS_SS : SV_POSITION;
    float2 screenUV : VAR_SCREEN_UV;
};

Varyings DefaultPassVertex(uint vertexID : SV_VertexID)
{
    Varyings output;
    output.positionCS_SS = float4(
        vertexID <= 1 ? -1.0 : 3.0,
        vertexID == 1 ? 3.0 : -1.0,//绘制在三角形的左下角，裁剪空间xy是-1~1
        0.0, 1.0
    );
    output.screenUV = float2(
        vertexID <= 1 ? 0.0 : 2.0,
        vertexID == 1 ? 2.0 : 0.0//屏幕空间，uv是0~1
    );
    
    if (_ProjectionParams.x < 0.0) {//如果x<0，则当前图形API导致需要y翻转才正确
        output.screenUV.y = 1.0 - output.screenUV.y;
    }
    
    return output;
}



float4 CopyPassFragment(Varyings input) : SV_Target
{
    return SAMPLE_TEXTURE2D_LOD(_SourceTexture, sampler_linear_clamp, input.screenUV, 0);
}

float CopyDepthPassFragment(Varyings input) : SV_Depth
{
    return SAMPLE_DEPTH_TEXTURE(_SourceTexture, sampler_point_clamp, input.screenUV);
}

#include "../ShaderLibrary/Surface.hlsl"
#include "../ShaderLibrary/Shadows.hlsl"
#include "../ShaderLibrary/Light.hlsl"
#include "../ShaderLibrary/BRDF.hlsl"
#include "../ShaderLibrary/GI.hlsl"
#include "../ShaderLibrary/Lighting.hlsl"

float4 DeferredLightPassFragment(Varyings input) : SV_Target
{
    float2 uv = input.screenUV;
    
    Surface surface;
    //深度图重建世界坐标
    float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
    float4 posClip = float4(uv * 2 - 1, depth, 1);
    #if UNITY_UV_STARTS_AT_TOP
    posClip.y = -posClip.y;  // 抵消 DefaultPassVertex 的 UV 翻转
    #endif
    float4 posWS = mul(UNITY_MATRIX_I_VP, posClip);
    posWS /= posWS.w;
    surface.position = posWS.xyz;
        
    //解码法线（GT1存储法线 * 0.5 + 0.5）
    float3 normal = SAMPLE_TEXTURE2D(_GBuffer2, sampler_linear_clamp, uv).xyz * 2.0 - 1.0;
    normal = normalize(normal);
    surface.normal = normal;
    surface.interpolatedNormal = normal;
    surface.viewDirection = normalize(_WorldSpaceCameraPos - surface.position);
    surface.depth = depth;//存疑？
    surface.color = SAMPLE_TEXTURE2D(_GBuffer1, sampler_linear_clamp, uv).rgb;
    surface.alpha = 1.0;
    
    float4 motionVec_Smoothness_Metallic = SAMPLE_TEXTURE2D(_GBuffer3, sampler_linear_clamp, uv);
    surface.metallic = motionVec_Smoothness_Metallic.w;
    surface.smoothness = motionVec_Smoothness_Metallic.z;
    
    float4 emission_Occlusion = SAMPLE_TEXTURE2D(_GBuffer4, sampler_linear_clamp, uv);
    surface.occlusion = emission_Occlusion.w;
    
    surface.fresnelStrength = 1;
    surface.dither = InterleavedGradientNoise(uv, 0);
    surface.renderingLayerMask = asuint(unity_RenderingLayer.x);
    
    BRDF brdf = GetBRDF(surface, false);
    
    float3 indirectDiffuse = SAMPLE_TEXTURE2D(_GBuffer5, sampler_linear_clamp, uv);
    
    //gi咋算？
    GI gi = GetGI(indirectDiffuse, surface, brdf);
    //gi.specular = float3(0,0,0);
    
    
    float3 color = GetLighting(surface, brdf, gi);
    float3 emission = emission_Occlusion.xyz;
    color += emission;
    
    //return float4(uv, 0 ,1);
    /// return float4(posClip.xyz, 1);
    //  return float4(depth.xxx, 1.0);
     //return float4(posWS.xyz *0.1 , 1.0);  // 世界坐标×缩放显示
    //
     //return float4(surface.viewDirection, 1.0);
     //return float4(gi.specular, 1.0);
    // return float4(GetLighting(surface, brdf, gi), 1.0);
    return float4(color, 1.0);
}

#endif
