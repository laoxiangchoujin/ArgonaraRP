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
            Name "ToneMapping None"
            
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DefaultPassVertex
            #pragma fragment ToneMappingNonePassFragment
			ENDHLSL
        }

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

		Pass
        {
            Name "LUT Final"
            
            //-----------
            //想象一个比较复杂的情况，a相机绘制整个屏幕，b相机的rect较小但画在a的画面上边。希望设置b的clearflag为天空盒，就只绘制b的场景物体到屏幕上，
            //1.在无后处理时是正确的
            //2.当开启了PostFx，我的管线会强制设置CameraClearFlags为color，那么b相机一定会用背景色填满b相机的rect区域，原本的b相机天空盒区域变成了b相机背景色
				//如果设置Alpha混合为Blend SrcAlpha OneMinusSrcAlpha，且将b的背景色alpha设为0，此时禁用bloom，剔除区域的最终结果就是：小相机颜色 × 0 + 下层颜色 × (1-0) = 下层颜色 √
            //3.此时，再启用bloom，b相机的bloom，不能扩散到透明区（也就是被按深度清除掉的区域），这不合适
				//换成预乘Alpha混合，也就是Blend One OneMinusSrcAlpha,就能让小窗口，既读取a相机的背景色，又能让b相机的bloom在b相机区域内，把光晕画到背景色上
				//此时要求，b相机的背景色的rgb纯黑，a是0，结果才对
            //-------------
            
            
            //相机叠加透明支持，混合模式由ArgonaraRenderPipelineCamera组件配置		//用来在特定的相机上达成上边注释所说的条件 ↑
            //默认One Zero(覆写)，覆盖相机设One OneMinusSrcAlpha(预乘Alpha叠加)
            Blend [_FinalSrcBlend] [_FinalDstBlend]
            
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DefaultPassVertex
            #pragma fragment FinalPassFragment
			ENDHLSL
        }

		Pass
		{
			Name "Final Rescale"
			//若渲染缩放就是1，只用上面的LUT Final Pass就行，无须如此
			//若有额外的渲染缩放，那么post fx最终画到屏幕上不能用上面的pass，那样会先rescale分辨率到屏幕分辨率，会让像素颜色之间做插值
			//1.tonemapping前是HDR颜色，HDR插值是不对的，例如1和10取均值还远大于1。2.缩放插值后的颜色和LUT查找表不匹配。两个问题
			//解决方式是先做color grading和tonemapping，再rescale到屏幕分辨率
			Blend [_FinalSrcBlend] [_FinalDstBlend]
			
			HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DefaultPassVertex
            #pragma fragment FinalPassFragmentRescale
			ENDHLSL
		}
    }
}
