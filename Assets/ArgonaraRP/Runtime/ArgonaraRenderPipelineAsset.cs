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

    //屏幕空间反射（SSR）：目前只有总开关，是否走SSR由它决定
    [SerializeField]
    SSRSettings ssr = default;

    public SSRSettings SSR => ssr;
    
    [SerializeField]
    PostFXSettings postFXSettings = default;
    
    public enum ColorLUTResolution {_16 = 16, _32 = 32, _64 = 64}
    
    [SerializeField]
    ColorLUTResolution colorLUTResolution = ColorLUTResolution._32;

    [SerializeField] 
    Shader cameraRendererShader = default;

    //注意：屏幕空间PCSS的shader引用已挪到 ShadowSettings.directional.pcss.shader，
    //SSR的shader引用在 SSRSettings 里 —— 各自跟着自己的设置走

    protected override RenderPipeline CreatePipeline()
    {
        return new ArgonaraRenderPipeline(cameraRendererType, cameraBuffer, useDynamicBatching, useGPUInstancing, useSRPBatcher, 
            useLightsPerObject, shadows, postFXSettings, (int)colorLUTResolution, cameraRendererShader, ssr);
    }
}
