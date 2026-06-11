Shader "Argonara RP/Lit"
{
    Properties
    {
        _BaseMap("Texture", 2D) = "white" {}
		_BaseColor("Color", Color) = (0.5, 0.5, 0.5, 1.0)
    }
    SubShader
    {

        Pass
        {
            Tags {
				"LightMode" = "ArgonaraLit"
			}
            HLSLPROGRAM
            #pragma multi_compile_instancing//它一定要写在vert和frag前面吗？为啥？
            #pragma vertex LitPassVertex
            #pragma fragment LitPassFragment
            #include "LitPass.hlsl"
            ENDHLSL
        }
    }
}
