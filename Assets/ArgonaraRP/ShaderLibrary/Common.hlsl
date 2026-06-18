#ifndef CUSTOM_COMMON_INCLUDED
#define CUSTOM_COMMON_INCLUDED

//汇入unity自带的参数库
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
//汇入自己写的参数库
#include "UnityInput.hlsl"

//以下一些define，相当于给矩阵改个名字
#define UNITY_MATRIX_M unity_ObjectToWorld
#define UNITY_MATRIX_I_M unity_WorldToObject
#define UNITY_MATRIX_V unity_MatrixV
#define UNITY_MATRIX_VP unity_MatrixVP
#define UNITY_MATRIX_P glstate_matrix_projection//这是？

//针对unity 2022需要的3个额外宏
#define UNITY_MATRIX_I_V unity_MatrixInvV
#define UNITY_PREV_MATRIX_M unity_prev_MatrixM//这俩是？
#define UNITY_PREV_MATRIX_I_M unity_prev_MatrixIM

//BRDF函数归纳
float Square(float v)
{
    return v*v;
}

float DistanceSquared(float3 pA, float3 pB) {
    return dot(pA - pB, pA - pB);
}

#if defined(_SHADOW_MASK_ALWAYS) || defined(_SHADOW_MASK_DISTANCE)//对于occlusion probe，UnityInstancing 仅在定义了 SHADOWS_SHADOWMASK 时才能实例化
    #define SHADOWS_SHADOWMASK
#endif

//支持GPU实例化，使能够访问实例化数据数组
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/UnityInstancing.hlsl"
//汇入矩阵到函数库中
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SpaceTransforms.hlsl"

#endif