using UnityEngine;
using UnityEditor;

[CanEditMultipleObjects]
[CustomEditorForRenderPipeline(typeof(Light), typeof(ArgonaraRenderPipelineAsset))]
public class CustomLightEditor : LightEditor
{
	public override void OnInspectorGUI()
	{
		base.OnInspectorGUI();//调用基本方法来正常绘制默认检查器

		if (!settings.lightType.hasMultipleDifferentValues &&//若没在选择多个类型的灯光
		    (LightType)settings.lightType.enumValueIndex == LightType.Spot)//且选择的都是聚光
		{
			settings.DrawInnerAndOuterSpotAngle();//绘制内外角滑块
			settings.ApplyModifiedProperties();//应用滑块所做的修改
		}
	}
}
