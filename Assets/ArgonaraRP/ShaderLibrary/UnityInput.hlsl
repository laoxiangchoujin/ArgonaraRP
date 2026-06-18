#ifndef CUSTOM_UNITY_INPUT_INCLUDED
#define CUSTOM_UNITY_INPUT_INCLUDED

//这些都是逐物体的数据
CBUFFER_START(UnityPerDraw)//要让shader兼容SRP batcher，第二，对custom input，要把这些矩阵放per Draw的CBuffer里
    float4x4 unity_ObjectToWorld;
    float4x4 unity_WorldToObject;
    float4 unity_LODFade;
    real4 unity_WorldTransformParams;//世界空间参数，是一些转换信息，，，？
    float3 _WorldSpaceCameraPos;

    float4 unity_LightmapST;
    float4 unity_DynamicLightmapST;//说是它已被弃用，但还是放上吧

    float4 unity_SHAr;//light probe用到的球谐数据（动态对象）
    float4 unity_SHAg;
    float4 unity_SHAb;
    float4 unity_SHBr;
    float4 unity_SHBg;
    float4 unity_SHBb;
    float4 unity_SHC;

    float4 unity_ProbeVolumeParams;//用于LPPV（光照探针proxy volume代理体积）的per Object Data（动态对象）
    float4x4 unity_ProbeVolumeWorldToObject;
    float4 unity_ProbeVolumeSizeInv;
    float4 unity_ProbeVolumeMin;

    float4 unity_ProbesOcclusion;//occlusion probe(阴影探针)的数据（动态对象）

    float4 unity_SpecCube0_HDR;
CBUFFER_END



float4x4 unity_MatrixVP;
float4x4 unity_MatrixV;
float4x4 glstate_matrix_projection;

float4x4 unity_MatrixInvV;
float4x4 unity_prev_MatrixM;
float4x4 unity_prev_MatrixIM;

#endif