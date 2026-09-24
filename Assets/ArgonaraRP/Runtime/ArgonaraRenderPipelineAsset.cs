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


    //Hi-Z（分层深度图）：**独立设置**，放在顶层（原来是塞在 SSR 里面的）。
    //它是被消费的资源：SSR 和 SSGI 共用同一份，"本帧要不要建"由消费它的特性决定
    //（渲染器传 useSSR || useSSGI）⇒ 它自己没有开关。
    [SerializeField] HierarchicalZSettings hiz = default;
    
    
    //屏幕空间反射（SSR）：目前只有总开关，是否走SSR由它决定
    [SerializeField]
    SSRSettings ssr = default;

    public SSRSettings SSR => ssr;


    //屏幕空间间接光（SSGI）：目前只接延迟（前向先不接）。Hi-Z 用它和 SSR 共用的顶层那份（hiz）
    [SerializeField] 
    ScreenSpaceIndirectDiffuseSettings screenSpaceIndirectDiffuse = default;
    

    //时域抗锯齿（TAA）：抖动投影矩阵 + 混合历史帧。shader 引用跟着它走（同 SSR/PCSS 一个套路）
    [SerializeField]
    TemporalAntiAliasingSettings temporalAntiAliasing = default;
    

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
            useLightsPerObject, shadows, postFXSettings, (int)colorLUTResolution, cameraRendererShader, ssr, temporalAntiAliasing,
            screenSpaceIndirectDiffuse, hiz);
    }
}
