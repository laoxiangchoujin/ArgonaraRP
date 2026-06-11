using UnityEngine;
using UnityEngine.Rendering;

[CreateAssetMenu(menuName = "Rendering/Argonara Render Pipeline Asset")]
public class ArgonaraRenderPipelineAsset : RenderPipelineAsset<ArgonaraRenderPipeline>
{
    [SerializeField]
    bool useDynamicBatching = true, useGPUInstancing = true, useSRPBatcher = true;
    
    protected override RenderPipeline CreatePipeline()
    {
        return new ArgonaraRenderPipeline(useDynamicBatching, useGPUInstancing, useSRPBatcher);
    }
}
