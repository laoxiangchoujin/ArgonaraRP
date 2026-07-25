using UnityEngine;


[System.Serializable]
public struct CameraBufferSettings
{
    public bool allowHDR;//全局是否允许HDR，单个相机还需camera.allowHDR也为true才生效

    public bool copyColor, copyColorReflection;//复制颜色缓冲快照（折射/扭曲等需要），反射探针单独控制
    public bool copyDepth, copyDepthReflection;

    [Range(CameraRendererForward.renderScaleMin, CameraRendererForward.renderScaleMax)] 
    public float renderScale;//渲染缩放，在单个双线性采样的时候，高于2的缩放，因为会跳过很多像素，反而会降低图像质量

    //当存在渲染缩放的时候，比例增大时用三线效果好，比例缩小时三线的效果不明显。若比例正好是2倍，三线和双线的效果完全一样。
    public enum BicubicRescalingMode {Off, OnRenderScaleBelowOne, Always}
    
    public BicubicRescalingMode bicubicRescaling;
}
