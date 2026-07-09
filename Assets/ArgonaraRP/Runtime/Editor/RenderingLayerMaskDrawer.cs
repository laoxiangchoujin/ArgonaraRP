using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

[CustomPropertyDrawer(typeof(RenderingLayerMaskFieldAttribute))]
public class RenderingLayerMaskDrawer : PropertyDrawer
{
    public static void Draw(Rect position, SerializedProperty property, GUIContent label)
    {
        EditorGUI.showMixedValue = property.hasMultipleDifferentValues;
        EditorGUI.BeginChangeCheck();
        int mask = property.intValue;
        bool isUint = property.type == "uint";//Light的掩码是uint，需处理-1↔int.MaxValue
        if (isUint && mask == int.MaxValue)
        {
            mask = -1;
        }
        string[] layerNames = GraphicsSettings.currentRenderPipeline?.renderingLayerMaskNames;
        if (layerNames == null)
        {
            layerNames = new string[32];
            for (int i = 0; i < 32; i++)
                layerNames[i] = "Layer" + (i + 1);
        }
        mask = EditorGUI.MaskField(position, label, mask, layerNames);
        if (EditorGUI.EndChangeCheck())
        {
            property.intValue = isUint && mask == -1 ? int.MaxValue : mask;
        }
        EditorGUI.showMixedValue = false;
    }

    public static void Draw(SerializedProperty property, GUIContent label)//无Rect版本，自动分配一行
    {
        Draw(EditorGUILayout.GetControlRect(), property, label);
    }

    public override void OnGUI(Rect position, SerializedProperty property, GUIContent label)
    {
        Draw(position, property, label);
    }
}
