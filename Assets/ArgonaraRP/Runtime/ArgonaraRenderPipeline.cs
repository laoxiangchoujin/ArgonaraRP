using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;

public partial class ArgonaraRenderPipeline : RenderPipeline
{
    //bool allowHDR;
    CameraBufferSettings cameraBufferSettings;
    bool useDynamicBatching = true;
    bool useGPUInstancing = true;
    bool useLightsPerObject;
    
    ShadowSettings shadowSettings;

    SSRSettings ssrSettings;

    PostFXSettings postFXSettings;

    TemporalAntiAliasingSettings taaSettings;

    int colorLUTResolution;
    
    //构造函数
    public ArgonaraRenderPipeline(ArgonaraRenderPipelineAsset.CameraRendererType cameraRenderType, CameraBufferSettings cameraBufferSettings, bool useDynamicBatching, bool useGPUInstancing, bool useSRPBatcher,
        bool useLightsPerObject, ShadowSettings shadowSettings, PostFXSettings postFXSettings, int colorLUTResolution,
        Shader cameraRendererShader, SSRSettings ssrSettings, TemporalAntiAliasingSettings taaSettings)
    {
        //this.allowHDR = allowHDR;
        this.cameraBufferSettings = cameraBufferSettings;
        this.useDynamicBatching = useDynamicBatching;
        this.useGPUInstancing = useGPUInstancing;
        GraphicsSettings.useScriptableRenderPipelineBatching = useSRPBatcher;//在创建pipeline时(构造函数里)，图像设置启用SRP batching，就能让compatible的shader自动做SRP batching
        GraphicsSettings.lightsUseLinearIntensity = true;//确保灯光颜色都是线性空间
        this.useLightsPerObject = useLightsPerObject;
        this.shadowSettings = shadowSettings;
        this.ssrSettings = ssrSettings;
        this.taaSettings = taaSettings;
        this.postFXSettings = postFXSettings;
        this.colorLUTResolution = colorLUTResolution;

        //屏幕空间PCSS的shader引用现在跟着PCSS的设置走（原来在管线asset顶层）
        Shader screenSpaceShadowShader = shadowSettings != null ? shadowSettings.directional.pcss.shader : null;

        forwardRenderer = new CameraRendererForward(cameraRendererShader, screenSpaceShadowShader);
        renderer = cameraRenderType == ArgonaraRenderPipelineAsset.CameraRendererType.forward
            ? forwardRenderer
            : new CameraRendererDeferred(cameraRendererShader, screenSpaceShadowShader);

        //切场景/卸场景：画面内容整个换了，但**相机没动** ⇒ TAA 的"瞬移判定"抓不到，必须显式让它丢历史
        SceneManager.activeSceneChanged += OnActiveSceneChanged;
        SceneManager.sceneUnloaded += OnSceneUnloaded;

        InitializeForEditor();
    }

    void OnActiveSceneChanged (Scene from, Scene to)
    {
        RequestResetHistory();
    }

    void OnSceneUnloaded (Scene scene)
    {
        RequestResetHistory();
    }

    //让两个渲染器（前向实例也管反射相机）都把 TAA 的历史标记成"下一帧不要混"
    void RequestResetHistory ()
    {
        renderer?.RequestResetHistory();
        forwardRenderer?.RequestResetHistory();
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
                shadowSettings, ssrSettings, postFXSettings, colorLUTResolution, taaSettings);
        }
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        SceneManager.activeSceneChanged -= OnActiveSceneChanged;//静态事件必须退订，否则旧管线实例会被一直抓着
        SceneManager.sceneUnloaded -= OnSceneUnloaded;
        DisposeForEditor();
        renderer.Dispose();
        forwardRenderer.Dispose();
    }
}
