using System.Collections;
using System.Collections.Generic;
using UnityEngine;

//TAA 的设置
[System.Serializable]
public class TemporalAntiAliasingSettings
{
    public bool enabled = false;
    [Range(0.01f, 0.5f)] public float blendFactor = 0.05f; //历史的混合比例，越小越稳、越容易鬼影
    [Range(0f, 500f)] public float motionBlendScale = 100f; //运动越大越信当前帧
    [Range(0f, 1f)] public float sharpenStrength = 0f; //可选锐化，0 = 不做
    [SerializeField] Shader shader = default;

    //渲染时才创建材质（材质不能序列化）；由 TAA 那边用、Dispose 时销毁
    [System.NonSerialized] Material material;
    public Material Material
    {
        get
        {
            if (material == null && shader != null)
            {
                material = new Material(shader);
                material.hideFlags = HideFlags.HideAndDontSave;
            }
            return material;
        }
    }
}
