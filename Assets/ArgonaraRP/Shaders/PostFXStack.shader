Shader "Hidden/ArgonaraRP/Post FX Stack"//hidden的好像不会在inspector里显示
{
    SubShader
    {
        Cull Off//后处理，，，不剔除，忽略深度，，，话说为啥不剔除
		ZTest Always
		ZWrite Off

		HLSLINCLUDE
		#include "../ShaderLibrary/Common.hlsl"
		#include "PostFXStackPasses.hlsl"
		ENDHLSL
		
		Pass {
			Name "Bloom Add"
			
			HLSLPROGRAM
				#pragma target 3.5
				#pragma vertex DefaultPassVertex
				#pragma fragment BloomAddPassFragment
			ENDHLSL
		}

		Pass {
			Name "Bloom Horizontal"
			
			HLSLPROGRAM
				#pragma target 3.5
				#pragma vertex DefaultPassVertex
				#pragma fragment BloomHorizontalPassFragment
			ENDHLSL
		}

		Pass {
			Name "Bloom Prefilter"
			
			HLSLPROGRAM
				#pragma target 3.5
				#pragma vertex DefaultPassVertex
				#pragma fragment BloomPrefilterPassFragment
			ENDHLSL
		}

		Pass {
			Name "Bloom PrefilterFireFlies"
			
			HLSLPROGRAM
				#pragma target 3.5
				#pragma vertex DefaultPassVertex
				#pragma fragment BloomPrefilterFirefliesPassFragment
			ENDHLSL
		}

		Pass {
			Name "Bloom Scatter"
			
			HLSLPROGRAM
				#pragma target 3.5
				#pragma vertex DefaultPassVertex
				#pragma fragment BloomScatterPassFragment
			ENDHLSL
		}

		Pass {
			Name "Bloom ScatterFinal"
			
			HLSLPROGRAM
				#pragma target 3.5
				#pragma vertex DefaultPassVertex
				#pragma fragment BloomScatterFinalPassFragment 
			ENDHLSL
		}

		Pass {
			Name "Bloom Vertical"
			
			HLSLPROGRAM
				#pragma target 3.5
				#pragma vertex DefaultPassVertex
				#pragma fragment BloomVerticalPassFragment
			ENDHLSL
		}

        Pass
        {
            Name "Copy"
            
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DefaultPassVertex
            #pragma fragment CopyPassFragment
			ENDHLSL
        }

		//------------------------ToneMapping------------------------//

        Pass
        {
            Name "ToneMapping ACES"
            
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DefaultPassVertex
            #pragma fragment ToneMappingACESPassFragment
			ENDHLSL
        }

        Pass
        {
            Name "ToneMapping Neutral"
            
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DefaultPassVertex
            #pragma fragment ToneMappingNeutralPassFragment
			ENDHLSL
        }

        Pass
        {
            Name "ToneMapping Reinhard"
            
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DefaultPassVertex
            #pragma fragment ToneMappingReinhardPassFragment
			ENDHLSL
        }
    }
}
