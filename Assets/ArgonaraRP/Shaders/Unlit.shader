Shader "Argonara RP/Unlit"
{
    Properties
    {
        _BaseMap("基础贴图",2D)="white"{}
        _BaseColor("基础颜色",Color) = (1,1,1,1)
        
        _Cutoff ("Alpha Cutoff", Range(0.0, 1.0)) = 0.5
        [Toggle(_CLIPPING)]_Clipping("Alpha Clipping",Float) = 0
        
        [Enum(UnityEngine.Rendering.BlendMode)]_SrcBlend("Src Blend",Float) = 1
        [Enum(UnityEngine.Rendering.BlendMode)]_DstBlend("Dst Blend",Float) = 0
        
        [Enum(Off,0,On,1)]_ZWrite("Z Write",Float) = 1
    }
    SubShader
    {

        Pass
        {
            Tags{"LightMode" = "SRPDefaultUnlit"}//不写Tag的LightMode的时候，就默认是SRPDefaultUnlit
            Blend [_SrcBlend] [_DstBlend]
            ZWrite [_ZWrite]
            
            HLSLPROGRAM
            #pragma shader_feature _CLIPPING
            #pragma multi_compile_instancing//它一定要写在vert和frag前面吗？为啥？
            #pragma vertex UnlitPassVertex
            #pragma fragment UnlitPassFragment
            #include "UnlitPass.hlsl"
            ENDHLSL
        }
    }
    CustomEditor "ArgonaraShaderGUI"
}
