using UnityEngine;
using UnityEngine.Rendering;

[CreateAssetMenu(menuName = "Rendering/Argonara Render Pipeline Asset")]
public class ArgonaraRenderPipelineAsset : RenderPipelineAsset<ArgonaraRenderPipeline>
{
    public enum CameraRendererType {forward, deferred}
    
    [SerializeField]
    CameraRendererType cameraRendererType = CameraRendererType.forward;
    
    //[SerializeField]
    //bool allowHDR = true;

    [SerializeField]
    CameraBufferSettings cameraBuffer = new CameraBufferSettings {
        allowHDR = true,
        renderScale = 1f
    };
    
    [SerializeField]
    bool useDynamicBatching = true, useGPUInstancing = true, useSRPBatcher = true, useLightsPerObject = true;
    
    [SerializeField]
    ShadowSettings shadows = default;
    
    //给调试代码等提供只读访问（如 Scene 视图里的级联球线框需要现算，直接从当前资产取设置）
    public ShadowSettings Shadows => shadows;
    
    [SerializeField]
    PostFXSettings postFXSettings = default;
    
    public enum ColorLUTResolution {_16 = 16, _32 = 32, _64 = 64}
    
    [SerializeField]
    ColorLUTResolution colorLUTResolution = ColorLUTResolution._32;

    [SerializeField] 
    Shader cameraRendererShader = default;
    
    protected override RenderPipeline CreatePipeline()
    {
        return new ArgonaraRenderPipeline(cameraRendererType, cameraBuffer, useDynamicBatching, useGPUInstancing, useSRPBatcher, 
            useLightsPerObject, shadows, postFXSettings, (int)colorLUTResolution, cameraRendererShader);
    }
}
