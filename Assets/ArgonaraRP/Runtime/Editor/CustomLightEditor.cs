using UnityEngine;
using UnityEngine.Rendering;
using UnityEditor;

[CanEditMultipleObjects]
[CustomEditorForRenderPipeline(typeof(Light), typeof(ArgonaraRenderPipelineAsset))]
public class CustomLightEditor : LightEditor
{
	static GUIContent renderingLayerMaskLabel =
		new GUIContent("Rendering Layer Mask", "Functional version of above property.");

	public override void OnInspectorGUI()
	{
		base.OnInspectorGUI();//调用基本方法来正常绘制默认检查器
		RenderingLayerMaskDrawer.Draw(settings.renderingLayerMask, renderingLayerMaskLabel);//补上LightEditor原生Rendering Layer Mask不生效的bug

		if (!settings.lightType.hasMultipleDifferentValues &&//若没在选择多个类型的灯光
		    (LightType)settings.lightType.enumValueIndex == LightType.Spot)//且选择的都是聚光
		{
			settings.DrawInnerAndOuterSpotAngle();//绘制内外角滑块
		}

		settings.ApplyModifiedProperties();//统一应用所有修改

		var light = target as Light;
		if (light.cullingMask != -1)//SRP下Culling Mask只影响阴影
		{
			EditorGUILayout.HelpBox(
				light.type == LightType.Directional ?
					"Culling Mask only affects shadows." :
					"Culling Mask only affects shadow unless Use Lights Per Objects is on.",
				MessageType.Warning);
		}
	}
}
