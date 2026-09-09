using UnityEngine;
using UnityEngine.Rendering;

[DisallowMultipleComponent, RequireComponent(typeof(Camera))]
public class ArgonaraRenderPipelineCamera : MonoBehaviour
{
    [SerializeField]
    CameraSettings settings = default;

    [SerializeField, Tooltip("显示级联阴影各级联的包围球线框")]
    bool cascadeDebug = false;

    public CameraSettings Settings => settings ?? (settings = new CameraSettings());

    //直接从“本组件所在相机 + 当前渲染管线资产的阴影设置”现算各级联包围球来画，
    //不再依赖该相机是否真的渲染过一帧（旧方案依赖 Shadows 渲染时的按相机缓存，只有实际渲染才刷新，
    //导致 Scene 视图里球不出/不跟随相机；且渲染的是选中相机的“副本”，缓存也刷不到原相机上）
    void OnDrawGizmos()
    {
        if (!cascadeDebug) { return; }
        Camera cam = GetComponent<Camera>();
        ArgonaraRenderPipelineAsset pipeline =
            GraphicsSettings.renderPipelineAsset as ArgonaraRenderPipelineAsset;
        if (pipeline == null) { return; }

        Vector4[] spheres = Shadows.ComputeDebugCascadeSpheres(cam, pipeline.Shadows);

        Color[] colors =
        {
            Color.red, new Color(1f, 0.5f, 0f), Color.yellow, Color.green,
            Color.cyan, Color.blue, Color.magenta, Color.white
        };
        for (int i = 0; i < spheres.Length; i++)
        {
            Vector4 sphere = spheres[i];
            if (sphere.w <= 0f) { continue; }
            Gizmos.color = colors[i % colors.Length];
            Gizmos.DrawWireSphere(new Vector3(sphere.x, sphere.y, sphere.z), sphere.w);
        }
    }
}
