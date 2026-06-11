#ifndef CUSTOM_COMMON_INCLUDED
#define CUSTOM_COMMON_INCLUDED

//汇入unity自带的参数库
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
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

//支持GPU实例化，使能够访问实例化数据数组
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/UnityInstancing.hlsl"
//汇入矩阵到函数库中
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SpaceTransforms.hlsl"

#endif