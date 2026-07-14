using Unity.Collections;
using UnityEngine;
using UnityEngine.Experimental.GlobalIllumination;
using LightType = UnityEngine.LightType;

public partial class ArgonaraRenderPipeline{
	partial void InitializeForEditor();

	partial void DisposeForEditor();

	//仅对于编辑器，重写light mapper设置光照数据的方式
	#if UNITY_EDITOR
		partial void InitializeForEditor()
		{
			Lightmapping.SetDelegate(lightsDelegate);//调用委托
		}

		partial void DisposeForEditor()//清理并重置委托
		{
			Lightmapping.ResetDelegate();
		}
	
		private static Lightmapping.RequestLightsDelegate lightsDelegate =//函数委托
			(Light[] lights, NativeArray<LightDataGI> output) =>//lambda表达式，//将数据从输入光照数组传输到 NativeArray<LightDataGI> 输出
			{
				var lightData = new LightDataGI();
				for (int i = 0; i < lights.Length; i++)
				{
					Light light = lights[i];
					switch (light.type)
					{
						case LightType.Directional:
							var directionalLight = new DirectionalLight();
							LightmapperUtils.Extract(light, ref directionalLight);
							lightData.Init(ref directionalLight);
							break;
						case LightType.Point:
							var pointLight = new PointLight();
							LightmapperUtils.Extract(light, ref pointLight);
							lightData.Init(ref pointLight);
							break;
						case LightType.Spot:
							var spotLight = new SpotLight();
							LightmapperUtils.Extract(light, ref spotLight);
							spotLight.innerConeAngle = light.innerSpotAngle * Mathf.Deg2Rad; //spot light顺便设置内角和角度衰减
							spotLight.angularFalloff = AngularFalloffType.AnalyticAndInnerAngle;
							lightData.Init(ref spotLight);
							break;
						case LightType.Rectangle:
							var rectangleLight = new RectangleLight();
							LightmapperUtils.Extract(light, ref rectangleLight);
							rectangleLight.mode = LightMode.Baked;//目前不支持实时区域灯光，先设为baked模式
							lightData.Init(ref rectangleLight);
							break;
						default:
							lightData.InitNoBake(light.GetInstanceID());//默认不烘焙灯光
							break;
					}

					lightData.falloff = FalloffType.InverseSquared;//这个是主要目的，以外的基本都是必需的模板代码
					output[i] = lightData;
				}
			};
	#endif
	
	
}
