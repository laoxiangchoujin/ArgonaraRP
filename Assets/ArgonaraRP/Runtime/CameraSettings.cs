using System;
using UnityEngine;
using UnityEngine.Rendering;

[Serializable]
public class CameraSettings
{
    [Serializable]
    public struct FinalBlendMode
    {
        public BlendMode source, destination;//Final pass的颜色混合模式，默认覆写
    }

    public FinalBlendMode finalBlendMode = new FinalBlendMode
    {
        source = BlendMode.One,
        destination = BlendMode.Zero
    };

    public bool overridePostFX = false;//设为true则使用本相机自己的后处理设置，替代管线全局设置

    public PostFXSettings postFXSettings = default;

    [RenderingLayerMaskField]
    public int renderingLayerMask = -1;//相机渲染层掩码，-1=所有层

    public bool maskLights = false;//是否同时对灯光应用渲染层过滤

    public bool copyColor = true, copyDepth = true;//本相机是否复制颜色/深度纹理（需管线全局也开启才生效）
}
