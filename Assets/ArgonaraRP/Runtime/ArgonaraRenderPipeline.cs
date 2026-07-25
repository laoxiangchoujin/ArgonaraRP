using UnityEngine;
using UnityEngine.Rendering;

public partial class ArgonaraRenderPipeline : RenderPipeline
{
    //bool allowHDR;
    CameraBufferSettings cameraBufferSettings;
    bool useDynamicBatching = true;
    bool useGPUInstancing = true;
    bool useLightsPerObject;
    
    ShadowSettings shadowSettings;

    PostFXSettings postFXSettings;
    
    int colorLUTResolution;
    
    //构造函数
    public ArgonaraRenderPipeline(ArgonaraRenderPipelineAsset.CameraRendererType cameraRenderType, CameraBufferSettings cameraBufferSettings, bool useDynamicBatching, bool useGPUInstancing, bool useSRPBatcher,
        bool useLightsPerObject, ShadowSettings shadowSettings, PostFXSettings postFXSettings, int colorLUTResolution,
        Shader cameraRendererShader)
    {
        //this.allowHDR = allowHDR;
        this.cameraBufferSettings = cameraBufferSettings;
        this.useDynamicBatching = useDynamicBatching;
        this.useGPUInstancing = useGPUInstancing;
        GraphicsSettings.useScriptableRenderPipelineBatching = useSRPBatcher;//在创建pipeline时(构造函数里)，图像设置启用SRP batching，就能让compatible的shader自动做SRP batching
        GraphicsSettings.lightsUseLinearIntensity = true;//确保灯光颜色都是线性空间
        this.useLightsPerObject = useLightsPerObject;
        this.shadowSettings = shadowSettings;
        this.postFXSettings = postFXSettings;
        this.colorLUTResolution = colorLUTResolution;

        forwardRenderer = new CameraRendererForward(cameraRendererShader);
        renderer = cameraRenderType == ArgonaraRenderPipelineAsset.CameraRendererType.forward
            ? forwardRenderer
            : new CameraRendererDeferred(cameraRendererShader);

        InitializeForEditor();
    }

    CameraRendererBase renderer;// = new CameraRenderer(); //它大致相当于URP的scriptable renderer
    CameraRendererForward forwardRenderer; // 始终创建，供反射相机用
    
    protected override void Render(ScriptableRenderContext context, Camera[] cameras)
    {
        foreach (Camera camera in cameras)
        {
            var r = camera.cameraType == CameraType.Reflection
                ? forwardRenderer//若是反射相机，哪怕管线设置为延迟，它自己也走前向
                : renderer;
            r.Render(context, camera, cameraBufferSettings,
                useDynamicBatching, useGPUInstancing, useLightsPerObject, 
                shadowSettings, postFXSettings, colorLUTResolution);
        }
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        DisposeForEditor();
        renderer.Dispose();
        forwardRenderer.Dispose();
    }
}
