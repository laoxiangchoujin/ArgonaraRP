using UnityEngine;
using UnityEngine.Rendering;

[CreateAssetMenu(menuName = "Rendering/Argonara Render Pipeline Asset")]
public class ArgonaraRenderPipelineAsset : RenderPipelineAsset<ArgonaraRenderPipeline>
{
    //[SerializeField]
    //bool allowHDR = true;

    [SerializeField]
    CameraBufferSettings cameraBuffer = new CameraBufferSettings {
        allowHDR = true
    };
    
    [SerializeField]
    bool useDynamicBatching = true, useGPUInstancing = true, useSRPBatcher = true, useLightsPerObject = true;
    
    [SerializeField]
    ShadowSettings shadows = default;
    
    [SerializeField]
    PostFXSettings postFXSettings = default;
    
    public enum ColorLUTResolution {_16 = 16, _32 = 32, _64 = 64}
    
    [SerializeField]
    ColorLUTResolution colorLUTResolution = ColorLUTResolution._32;

    [SerializeField] 
    Shader cameraRendererShader = default;
    
    protected override RenderPipeline CreatePipeline()
    {
        return new ArgonaraRenderPipeline(cameraBuffer, useDynamicBatching, useGPUInstancing, useSRPBatcher, 
            useLightsPerObject, shadows, postFXSettings, (int)colorLUTResolution, cameraRendererShader);
    }
}
