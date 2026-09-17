#ifndef CUSTOM_CAMERA_RENDERER_PASSES_INCLUDED
#define CUSTOM_CAMERA_RENDERER_PASSES_INCLUDED

TEXTURE2D(_SourceTexture);

TEXTURE2D(_GBuffer1);//rgb是albedo,a的前4位是shadingModelID
TEXTURE2D(_GBuffer2);//rgb是world normal
TEXTURE2D(_GBuffer3);//roughness,metallic,occlusion
TEXTURE2D(_GBuffer4);//rgb是emission
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

//（全屏 pass 的两个公共工具 —— 深度→世界坐标、几何面法线 —— 现在住在 ShaderLibrary/Fragment.hlsl 里，
//  因为屏幕空间 PCSS 也要用；本文件经由 Common.hlsl 仍然看得见它们）

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
    float3 emission_indirectColor = GT4.rgb;
    
    float3 output = 0.0;
    
    //所有着色模型现在都采样深度图，因为，如果相机的ClearFlags为Color，要如此判断远处，以保留清除色
    float GTDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_point_clamp, uv);
    if (GTDepth < 0.00001)
        return SAMPLE_TEXTURE2D(_CameraColorTexture, sampler_linear_clamp, uv);
    
    //unlit == 0
    if (shadingModelID == 0)
    {
        output = color + emission_indirectColor;
        return float4(output, 1.0);
    }
    //lit == 1
    else if (shadingModelID == 1)
    {
        Surface surface;
        //深度图重建世界坐标（公共工具，见 Fragment.hlsl）
        surface.position = ScreenSpaceWorldPosFromDepth(uv, GTDepth);
        
        //解码法线（GT1存储法线 * 0.5 + 0.5）
        float3 normal = SAMPLE_TEXTURE2D(_GBuffer2, sampler_linear_clamp, uv).xyz * 2.0 - 1.0;
        normal = normalize(normal);
        surface.normal = normal;
        surface.viewDirection = normalize(_WorldSpaceCameraPos - surface.position);
        surface.depth = -TransformWorldToView(surface.position).z;

        //阴影偏移用的"几何面法线"（不含法线图扰动）：全屏 pass 没顶点内插法线，用深度邻居重构（见函数头）
        surface.interpolatedNormal = ScreenSpaceGeometricNormal(surface.position, surface.depth, normal, uv);
        surface.albedo = color;
        surface.alpha = 1.0;
    
        float4 GT3 = SAMPLE_TEXTURE2D(_GBuffer3, sampler_linear_clamp, uv);
        surface.roughness = GT3.x;
        surface.metallic = GT3.y;
        surface.occlusion = GT3.z;
        
        //surface.fresnelStrength = 1;
        //必须传“像素坐标”！uv 是 0~1 的屏幕 UV，用它当 IGN 的输入高频噪点会退化成一条低频渐变
        //（整个屏幕只绕约 4 圈），dither 混合就近似硬切；改用 SV_Position，语义与 forward 的 config.fragment.positionSS 一致
        surface.dither = InterleavedGradientNoise(input.positionCS_SS.xy, 0);
        surface.renderingLayerMask = asuint(unity_RenderingLayer.x);
    
        BRDF brdf = GetBRDF(surface, false);
        
    
        
    
    
        color = GetLightingDeferred(surface, brdf);

        //return float4(surface.albedo, 1);
        //return float4(surface.normal * 0.5 + 0.5, 1);
        //return float4((surface.position * 0.05), 1);
        //color = GetDirectionalLightCount();
        color += emission_indirectColor;
    
        return float4(color, 1.0);
    }
    
    //说明是出错的，返回一个红色
    output = float3(1,0,0);
    return float4(output, 1.0);
}

#endif
