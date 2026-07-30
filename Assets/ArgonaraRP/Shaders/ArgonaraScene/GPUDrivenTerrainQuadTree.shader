Shader "Argonara RP/Scene/Terrain QuadTree Visualization"
{
	Properties
	{
		_Color ("Color", Color) = (0.8, 0.8, 0.8, 1)
	}

	SubShader
	{
		Tags { "RenderType" = "Transparent" "Queue" = "Overlay" }
		Blend SrcAlpha OneMinusSrcAlpha
		ZWrite Off
		Cull Off
		LOD 100

		Pass
		{
			HLSLPROGRAM
			#pragma vertex vert
			#pragma fragment frag

			#define UNITY_PROCEDURAL_INSTANCING_ENABLED
			#pragma instancing_options procedural:setup

			#include "../../ShaderLibrary/Common.hlsl"

			CBUFFER_START(UnityPerMaterial)
			float4 _Color;
			CBUFFER_END

			struct Node
			{
				float3 pos;
				int2 indexxy;
				float width;
				int lodLevel;
			};
			StructuredBuffer<Node> afterCulling;

			float4x4 _Matrix;

			// 按 node 的宽度做一个平移 + 缩放的矩阵
			void setup()
			{
				Node node = afterCulling[unity_InstanceID];
				float s = node.width * 0.5 / 4 * 0.95; // 半宽作为缩放，使 Cube 刚好填满 node 区域
				_Matrix = float4x4(
					s, 0, 0, node.pos.x,
					0, s, 0, node.pos.y,
					0, 0, s, node.pos.z,
					0, 0, 0, 1
				);
			}

			struct Attributes
			{
				float4 posOS : POSITION;
				UNITY_VERTEX_INPUT_INSTANCE_ID
			};

			struct Varyings
			{
				float4 posCS : SV_POSITION;
				float4 color : COLOR0;
				UNITY_VERTEX_INPUT_INSTANCE_ID
			};

			Varyings vert(Attributes v)
			{
				Varyings o;
				UNITY_SETUP_INSTANCE_ID(v);
				UNITY_TRANSFER_INSTANCE_ID(v, o);

				float3 worldPos = mul(_Matrix, v.posOS).xyz - float3(0,10,0);
				o.posCS = TransformWorldToHClip(worldPos);
				o.color = _Color;
				return o;
			}

			float4 frag(Varyings i) : SV_Target
			{
				return i.color;
			}
			ENDHLSL
		}
	}
}
