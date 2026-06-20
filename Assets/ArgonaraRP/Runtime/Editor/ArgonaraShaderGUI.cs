using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using System.Collections.Generic;

//自定义Shader GUI类
public class ArgonaraShaderGUI : ShaderGUI
{
    private bool showPresets;//是否展示一些预设的选项
    
    private MaterialEditor editor;//材质编辑器
    private Object[] materials;//对正在编辑的材质的引用
    MaterialProperty[] properties;//属性数组
    public override void OnGUI(MaterialEditor materialEditor, MaterialProperty[] properties)
    {
        EditorGUI.BeginChangeCheck();
        
        editor = materialEditor;
        materials = editor.targets;//从通用类editor的target获取材质
        this.properties = properties;

        base.OnGUI(materialEditor, FilterHiddenProperties(properties));//首先获取GUI面板，并过滤隐藏的属性
        
        BakedEmission();

        showPresets = EditorGUILayout.Foldout(showPresets, "Presets", true);
        if (showPresets)//默认foldout折叠的，点击才显示
        {
            OpaquePreset();
            OpaqueClipPreset();
            AllFadePreset();
            TransparentPreset();
        }

        if (EditorGUI.EndChangeCheck())
        {
            SetShadowCasterPass();
            CopyLightMappingProperties();
        }
    }

    MaterialProperty[] FilterHiddenProperties(MaterialProperty[] props)
    {
        var filtered = new List<MaterialProperty>();
        bool maskOn = FindProperty("_MaskMapToggle", props, false)?.floatValue > 0;
        bool normalOn = FindProperty("_NormalMapToggle", props, false)?.floatValue > 0;
        bool detailOn = FindProperty("_DetailMapToggle", props, false)?.floatValue > 0;

        foreach (var p in props)
        {
            if (!maskOn && p.name == "_MaskMap") continue;
            if (!normalOn && (p.name == "_NormalMap" || p.name == "_NormalScale")) continue;
            if (!detailOn && (p.name == "_DetailMap" || p.name == "_DetailAlbedo" ||
                p.name == "_DetailSmoothness" || p.name == "_DetailNormalMap" || p.name == "_DetailNormalScale")) continue;
            filtered.Add(p);
        }
        return filtered.ToArray();
    }

    ///设置float属性
    bool SetProperty(string name, float value)
    {
        //这函数是ShaderGUI.FindProperty
        //从properties里找到名为name的属性，赋值
        MaterialProperty property = FindProperty(name, properties, false);//mandatory强制性的，设为false，让没找到这个属性时，不报错，返回null
        if (property != null)
        {
            property.floatValue = value;
            return true;
        }

        return false;
    }

    ///设置关键字
    void SetKeyword(string keyword, bool enabled)
    {
        if (enabled)
        {
            foreach (Material m in materials)
            {
                m.EnableKeyword(keyword);
            }
        }
        else
        {
            foreach (Material m in materials)
            {
                m.DisableKeyword(keyword);
            }
        }
    }

    ///设置关键字的组合，例如，当写"Clipping = false"赋值的时候，自动调其中的set访问器，调SetProperty，然后，根据bool value，设置"_Clipping"和"_CLIPPING"的值
    void SetProperty(string name, string keyword, bool value)
    {
        if (SetProperty(name, value ? 1f : 0f))//先看能否找到属性，有才赋值
        {
            SetKeyword(keyword, value);
        }
    }

    //这些都什么写法？
    //注意到这些东西都没小写
    bool Clipping
    {
        set => SetProperty("_Clipping", "_CLIPPING", value);
    }
    
    /*
    这个是传统写法，效果上跟那个"=>"一样的
    bool Clipping
    {
        set
        {
            SetProperty("_Clipping", "_CLIPPING", value);
        }
    }*/
     

    bool PremultiplyAlpha
    {
        set => SetProperty("_PremulAlpha", "_PREMULTIPLY_ALPHA", value);
    }

    BlendMode SrcBlend
    {
        set => SetProperty("_SrcBlend", (float)value);
    }

    BlendMode DstBlend
    {
        set => SetProperty("_DstBlend", (float)value);
    }

    bool ZWrite
    {
        set => SetProperty("_ZWrite", value ? 1f : 0f);
    }

    RenderQueue RenderQueue//不懂，何意味
    {
        set
        {
            foreach (Material m in materials)
            {
                m.renderQueue = (int)value;
            }
        }
    }

    ///预设按钮
    bool PresetButton(string name)
    {
        if (GUILayout.Button(name))
        {
            editor.RegisterPropertyChangeUndo(name);//为了能够撤销
            return true;
        }

        return false;
    }
    
    ///为每个预设单独弄个函数，每个预设是一个组合
    ///不透明预设
    void OpaquePreset()
    {
        if (PresetButton("Opaque"))
        {
            Clipping = false;
            Shadows = ShadowMode.On;
            PremultiplyAlpha = false;
            SrcBlend = BlendMode.One;
            DstBlend = BlendMode.Zero;
            ZWrite = true;
            RenderQueue = RenderQueue.Geometry;
        }
    }

    void OpaqueClipPreset()
    {
        if (PresetButton("OpaqueClip"))
        {
            Clipping = true;
            Shadows = ShadowMode.Clip;
            PremultiplyAlpha = false;
            SrcBlend = BlendMode.One;
            DstBlend = BlendMode.Zero;
            ZWrite = true;
            RenderQueue = RenderQueue.AlphaTest;
        }
    }
    
    ///diffuse和specular都随着alpha褪色的预设
    void AllFadePreset()
    {
        if (PresetButton("AllFade"))
        {
            Clipping = false;
            Shadows = ShadowMode.Dither;
            PremultiplyAlpha = false;
            SrcBlend = BlendMode.SrcAlpha;
            DstBlend = BlendMode.OneMinusSrcAlpha;
            ZWrite = false;
            RenderQueue = RenderQueue.Transparent;
        }
    }

    ///预乘alpha混合的玻璃trans预设
    void TransparentPreset()
    {
        if (HasPremultiplyAlpha && PresetButton("Transparent"))//材质需要有_PremulAlpha这个属性，才显示这个预设按钮
        {
            Clipping = false;
            Shadows = ShadowMode.Dither;
            PremultiplyAlpha = true;
            SrcBlend = BlendMode.One;
            DstBlend = BlendMode.OneMinusSrcAlpha;
            ZWrite = false;
            RenderQueue = RenderQueue.Transparent;
        }
    }
    
    bool HasProperty(string name)=>//判断property是否存在
        FindProperty(name, properties, false) != null;
    
    bool HasPremultiplyAlpha => HasProperty("_PremulAlpha");

    enum ShadowMode
    {
        On, Clip, Dither, Off
    }

    ShadowMode Shadows
    {
        set
        {
            if (SetProperty("_Shadows", (float)value))//_Shadows是对应材质面板上的keyWord enum，给它赋值就是改这个enum在显示什么
            {
                SetKeyword("_SHADOWS_CLIP", value == ShadowMode.Clip);//这两步才是真的给关键词赋值
                SetKeyword("_SHADOWS_DITHER", value == ShadowMode.Dither);
            }
        }
    }

    ///实现逐材质的禁用阴影，能同时禁用同一材质所有物体的阴影，比meshRenderer的禁用单个物体阴影的操作高效一些（真高效吗？）
    void SetShadowCasterPass()
    {
        MaterialProperty shadows = FindProperty("_Shadows", properties, false);
        if (shadows == null || shadows.hasMixedValue) //hasMixedValue检查所选的所有材质，比如你同时选了仨不同材质，若它们的_Shadows有不一样的就为true，因为这样不知道该开还是关
        {
            return;
        }
        bool enabled = shadows.floatValue < (float)ShadowMode.Off;
        foreach (Material m in materials)
        {
            m.SetShaderPassEnabled("ShadowCaster", enabled);//如果shadows是Off，那么它==Mode.Off，enabled为false，ShadowCaster这个pass被关闭
        }
    }

    ///用于显示一个"全局光照"的菜单，实际只影响自发光的烘焙，也就是unity_MetaFragmentControl.y
    void BakedEmission()
    {
        EditorGUI.BeginChangeCheck();
        editor.LightmapEmissionProperty();// 画出 GI 下拉菜单（None/Baked/Realtime）
        if (EditorGUI.EndChangeCheck()) // 用户改了菜单选项
        {
            foreach (Material m in editor.targets)
            {
                //清除 EmissiveIsBlack 标记，这个标记是，若材质的自发光为黑色，就跳过烘焙，是个优化
                //就是说，如果只在我的自定义GUI里，改了LightmapEmissionProperty()，unity可能不知道它改了，仍然跳过
                m.globalIlluminationFlags &= ~MaterialGlobalIlluminationFlags.EmissiveIsBlack;
            }
        }
    }

    void CopyLightMappingProperties()
    {
        MaterialProperty mainTex = FindProperty("_MainTex", properties, false);
        MaterialProperty baseMap = FindProperty("_BaseMap", properties, false);
        if (mainTex != null && baseMap != null)
        {
            mainTex.textureValue = baseMap.textureValue;
            mainTex.textureScaleAndOffset = baseMap.textureScaleAndOffset;
        }

        MaterialProperty color = FindProperty("_Color", properties, false);
        MaterialProperty baseColor = FindProperty("_BaseColor", properties, false);
        if (color != null && baseColor != null)
        {
            color.colorValue = baseColor.colorValue;
        }
    }
}
