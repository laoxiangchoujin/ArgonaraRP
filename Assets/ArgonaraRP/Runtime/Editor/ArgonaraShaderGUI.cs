using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using System.Collections.Generic;

//自定义Shader GUI类
public class ArgonaraShaderGUI : ShaderGUI
{
    private bool showPresets;
    private bool showStencil;
    private bool showMain = true;
    private bool showNormal = true;
    private bool showEmission = true;
    private bool showAlpha = true;
    private bool showMask = true;
    private bool showDetail = true;
    private bool showRendering = true;

    private static readonly Color _headerBg = new Color(1.555f, 1.555f, 1.555f);//这个是在原GUI颜色上乘算的

    void FoldoutGroup(ref bool show, string title, System.Action drawContent)
    {
        var prev = GUI.backgroundColor;
        GUI.backgroundColor = _headerBg;
        show = EditorGUILayout.BeginFoldoutHeaderGroup(show, title);
        GUI.backgroundColor = prev;
        if (show)
        {
            EditorGUI.indentLevel++;
            drawContent?.Invoke();
            EditorGUI.indentLevel--;
        }
        EditorGUILayout.EndFoldoutHeaderGroup();
        EditorGUILayout.Space(12);
    }
    
    private MaterialEditor editor;//材质编辑器
    private Object[] materials;//对正在编辑的材质的引用
    MaterialProperty[] properties;//属性数组
    public override void OnGUI(MaterialEditor materialEditor, MaterialProperty[] properties)
    {
        EditorGUI.BeginChangeCheck();
        
        editor = materialEditor;
        materials = editor.targets;//从通用类editor的target获取材质
        this.properties = properties;

        //1.手动绘制，我指定的分组属性
        DrawGroups();
        //2.unity GUI画剩下未绘制的属性
        base.OnGUI(materialEditor, FilterHiddenProperties(properties));//首先获取GUI面板，未分组的属性（含新增的）由 base 自动显示
        //3.预设按钮
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
        // 以下属性已由 DrawGroups 手动分组绘制，交给 base.OnGUI 时须隐藏，避免重复显示。
        // 未在集合中的属性（含你将来新增的）仍会由 base.OnGUI 自动显示。
        var grouped = new HashSet<string>
        {
            "_BaseMap", "_BaseColor",
            "_Clipping", "_Cutoff",
            "_Mask_Map", "_Metallic", "_Occlusion", "_Roughness",
            "_SingleMaskMap", "_MetallicMap", "_OcclusionMap", "_RoughnessMap",
            "_NormalMapToggle", "_NormalMap", "_NormalScale",
            "_DetailMapToggle", "_DetailMaskMap", "_DetailMap", "_DetailNormalMap",
            "_DetailAlbedo", "_DetailRoughness", "_DetailNormalScale",
            "_EmissionToggle", "_EmissionMap", "_EmissionColor",
            "_PremulAlpha", "_SrcBlend", "_DstBlend", "_ZWrite", "_Shadows", "_ReceiveShadows",
            "_StencilRef", "_StencilComp", "_StencilOp"
        };
        var filtered = new List<MaterialProperty>();
        foreach (var p in props)
        {
            if (!grouped.Contains(p.name))
                filtered.Add(p);
        }
        return filtered.ToArray();
    }

    void DrawProperty(string name, string label = null)
    {
        MaterialProperty p = FindProperty(name, properties, false);
        if (p != null)
            editor.ShaderProperty(p, label ?? p.displayName);
    }

    bool IsOn(string name)
    {
        MaterialProperty p = FindProperty(name, properties, false);
        return p != null && p.floatValue > 0.5f;
    }

    // 只把用户明确要求分组的内容放到组里；其余属性交给 base.OnGUI 自动显示
    void DrawGroups()
    {
        FoldoutGroup(ref showMain, "Main Maps", () =>
        {
            var baseMap = FindProperty("_BaseMap", properties);
            var baseColor = FindProperty("_BaseColor", properties);
            editor.TexturePropertySingleLine(new GUIContent("基础贴图"), baseMap, baseColor);
            editor.TextureScaleOffsetProperty(baseMap);
        });

        FoldoutGroup(ref showAlpha, "Alpha Clipping", () =>
        {
            DrawProperty("_Clipping");
            if (IsOn("_Clipping"))
                DrawProperty("_Cutoff");
        });

        FoldoutGroup(ref showMask, "Mask Map", () =>
        {
            DrawProperty("_Mask_Map");
            int maskMode = (int)(FindProperty("_Mask_Map", properties, false)?.floatValue ?? 0);
            if (maskMode == 0)
            {
                DrawProperty("_Roughness");
                DrawProperty("_Metallic");
            }
            if (maskMode == 1)
            {
                DrawProperty("_SingleMaskMap");
                DrawProperty("_Roughness");
                DrawProperty("_Metallic");
                DrawProperty("_Occlusion");
            }
            else if (maskMode == 2)
            {
                editor.TexturePropertySingleLine(
                    new GUIContent("_RoughnessMap", "Roughness Map"),
                    FindProperty("_RoughnessMap", properties),
                    FindProperty("_Roughness", properties)
                );
                editor.TexturePropertySingleLine(
                    new GUIContent("_MetallicMap", "Metallic Map"),
                    FindProperty("_MetallicMap", properties),
                    FindProperty("_Metallic", properties)
                );
                editor.TexturePropertySingleLine(
                    new GUIContent("_OcclusionMap", "Occlusion Map"),
                    FindProperty("_OcclusionMap", properties),
                    FindProperty("_Occlusion", properties)
                );
            }
        });

        FoldoutGroup(ref showNormal, "Normal Map", () =>
        {
            DrawProperty("_NormalMapToggle");
            if (IsOn("_NormalMapToggle"))
            {
                editor.TexturePropertySingleLine(
                    new GUIContent("_NormalMap", "法线贴图"),
                    FindProperty("_NormalMap", properties),
                    FindProperty("_NormalScale", properties)
                );
            }
        });

        FoldoutGroup(ref showDetail, "Detail Maps", () =>
        {
            DrawProperty("_DetailMapToggle");
            if (IsOn("_DetailMapToggle"))
            {
                DrawProperty("_DetailMaskMap");
                DrawProperty("_DetailMap");
                DrawProperty("_DetailAlbedo");
                DrawProperty("_DetailRoughness");
                if (IsOn("_NormalMapToggle"))
                {
                    editor.TexturePropertySingleLine(
                        new GUIContent("_DetailNormalMap", "Detail Normal"),
                        FindProperty("_DetailNormalMap", properties),
                        FindProperty("_DetailNormalScale", properties)
                    );
                }
            }
        });

        FoldoutGroup(ref showEmission, "Emission", () =>
        {
            DrawProperty("_EmissionToggle");
            if (IsOn("_EmissionToggle"))
            {
                editor.TexturePropertyWithHDRColor(
                    new GUIContent("_EmissionMap", "自发光贴图"),
                    FindProperty("_EmissionMap", properties),
                    FindProperty("_EmissionColor", properties),
                    false
                );
                BakedEmission();
            }
        });

        FoldoutGroup(ref showRendering, "Rendering", () =>
        {
            DrawProperty("_PremulAlpha");
            DrawProperty("_SrcBlend");
            DrawProperty("_DstBlend");
            DrawProperty("_ZWrite");
            DrawProperty("_Shadows");
            DrawProperty("_ReceiveShadows");
        });

        FoldoutGroup(ref showStencil, "Stencil", () =>
        {
            DrawProperty("_StencilRef");
            DrawProperty("_StencilComp");
            DrawProperty("_StencilOp");
        });
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
