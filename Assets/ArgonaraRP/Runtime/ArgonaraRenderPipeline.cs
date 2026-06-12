using UnityEngine;
using UnityEngine.Rendering;

public class ArgonaraRenderPipeline : RenderPipeline
{
    bool useDynamicBatching = true;
    bool useGPUInstancing = true;
    
    //构造函数
    public ArgonaraRenderPipeline(bool useDynamicBatching, bool useGPUInstancing, bool useSRPBatcher)
    {
        this.useDynamicBatching = useDynamicBatching;
        this.useGPUInstancing = useGPUInstancing;
        GraphicsSettings.useScriptableRenderPipelineBatching = useSRPBatcher;//在创建pipeline时(构造函数里)，图像设置启用SRP batching，就能让compatible的shader自动做SRP batching
        GraphicsSettings.lightsUseLinearIntensity = true;//确保灯光颜色都是线性空间
    }

    CameraRenderer renderer = new CameraRenderer(); //它大致相当于URP的scriptable renderer
    
    protected override void Render(ScriptableRenderContext context, Camera[] cameras)
    {
        foreach (Camera camera in cameras)
        {
            renderer.Render(context, camera, useDynamicBatching, useGPUInstancing);
        }
    }
}
