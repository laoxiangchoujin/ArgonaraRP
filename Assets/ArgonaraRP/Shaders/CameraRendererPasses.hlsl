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

//GBuffer全屏三角光照计算，处理Opaque物体，应针对不同着色模型有不同处理
float4 DeferredLightPassFragment(Varyings input) : SV_Target
{
    float2 uv = input.screenUV;
    
    //先获取必需数据
    float4 GT1 = SAMPLE_TEXTURE2D(_GBuffer1, sampler_linear_clamp, uv);
    float3 color = GT1.rgb;
    uint shadingModelID = (uint)(GT1.a * 255.0 + 0.5) >> 4;
    
    //return float4(GT1.a*10, 0, 0, 1);
    //return float4(((float)shadingModelID).xxx, 1.0);
    
    float3 GT4 = SAMPLE_TEXTURE2D(_GBuffer4, sampler_linear_clamp, uv).rgb;
    float3 emission = GT4.rgb;
    
    float3 output = 0.0;
    
    //0.简单处理unlit
    
    if (shadingModelID == 0)
    {
        output = color + emission;
        return float4(output, 1.0);
    }
    else if (shadingModelID == 1)
    {
        Surface surface;
        //深度图重建世界坐标
        float GTDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
        float4 posClip = float4(uv * 2 - 1, GTDepth, 1);
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
        surface.depth = GTDepth;//存疑？
        surface.albedo = SAMPLE_TEXTURE2D(_GBuffer1, sampler_linear_clamp, uv).rgb;
        surface.alpha = 1.0;
    
        float4 GT3 = SAMPLE_TEXTURE2D(_GBuffer3, sampler_linear_clamp, uv);
        surface.smoothness = GT3.x;
        surface.metallic = GT3.y;
        surface.occlusion = GT3.z;
    
        float4 GT4 = SAMPLE_TEXTURE2D(_GBuffer4, sampler_linear_clamp, uv);
        
        //surface.fresnelStrength = 1;
        surface.dither = InterleavedGradientNoise(uv, 0);
        surface.renderingLayerMask = asuint(unity_RenderingLayer.x);
    
        BRDF brdf = GetBRDF(surface, false);
    
        float3 GT5 = SAMPLE_TEXTURE2D(_GBuffer5, sampler_linear_clamp, uv);
        float3 indirectDiffuse = GT5.rgb;
    
        //gi咋算？
        GI gi = GetGI(indirectDiffuse, surface, brdf);
        //gi.specular = float3(0,0,0);
    
    
        color = GetLighting(surface, brdf, gi);
        emission = GT4.xyz;
        color += emission;
    
        return float4(color, 1.0);
    }
    
    //说明是出错的，返回一个红色
    output = float3(1,0,0);
    return float4(output, 1.0);
}

#endif
