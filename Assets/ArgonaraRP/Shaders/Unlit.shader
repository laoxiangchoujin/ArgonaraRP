Shader "Argonara RP/Unlit"
{
    Properties
    {
        _BaseColor("基础颜色",Color) = (1,1,1,1)
    }
    SubShader
    {

        Pass
        {
            Tags{"LightMode" = "SRPDefaultUnlit"}
            HLSLPROGRAM
            #pragma multi_compile_instancing//它一定要写在vert和frag前面吗？为啥？
            #pragma vertex UnlitPassVertex
            #pragma fragment UnlitPassFragment
            #include "UnlitPass.hlsl"
            ENDHLSL
        }
    }
}
