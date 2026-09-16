using UnityEngine;


[System.Serializable]
public struct CameraBufferSettings
{
    public bool allowHDR;//全局是否允许HDR，单个相机还需camera.allowHDR也为true才生效

    public bool copyColor, copyColorReflection;//复制颜色缓冲快照（折射/扭曲等需要），反射探针单独控制
    public bool copyDepth, copyDepthReflection;

    //颜色快照要不要顺带建一条 mip 链：SSR 这类"按粗糙度/命中距离取不同模糊程度"的效果要用它——
    //采样时给个 mip level 就等于白拿模糊，不用为每个粗糙度各跑一趟模糊。
    //代价：拷颜色的同时多跑一次 GenerateMips（一次全屏）＋显存约 +33%。
    //关掉 = 和以前完全一样（_CameraColorTexture 只有 mip0）。
    public bool copyColorMips;
    //要建几级：1 = 只有自己（= 不建链）；2 = 自己 + 一张 1/2 的；3 = 再加一张 1/4 的……常用 4~5。
    //填超过分辨率能容纳的级数会被自动夹掉。
    [Tooltip("颜色快照要建几级 mip（含自己）：1 = 只有自己（不建链）；2 = 自己 + 一张 1/2 的；3 = 再加一张 1/4 的……常用 4~5")]
    [Range(1, 10)] public int copyColorMipCount;

    [Range(CameraRendererForward.renderScaleMin, CameraRendererForward.renderScaleMax)] 
    public float renderScale;//渲染缩放，在单个双线性采样的时候，高于2的缩放，因为会跳过很多像素，反而会降低图像质量

    //当存在渲染缩放的时候，比例增大时用三线效果好，比例缩小时三线的效果不明显。若比例正好是2倍，三线和双线的效果完全一样。
    public enum BicubicRescalingMode {Off, OnRenderScaleBelowOne, Always}
    
    public BicubicRescalingMode bicubicRescaling;
}
