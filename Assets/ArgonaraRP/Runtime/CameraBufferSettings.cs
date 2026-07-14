using System;

[System.Serializable]
public struct CameraBufferSettings
{
    public bool allowHDR;//全局是否允许HDR，单个相机还需camera.allowHDR也为true才生效

    public bool copyColor, copyColorReflection;//复制颜色缓冲快照（折射/扭曲等需要），反射探针单独控制
    public bool copyDepth, copyDepthReflection;
}
