using UnityEngine;

[DisallowMultipleComponent, RequireComponent(typeof(Camera))]
public class ArgonaraRenderPipelineCamera : MonoBehaviour
{
    [SerializeField]
    CameraSettings settings = default;

    public CameraSettings Settings => settings ?? (settings = new CameraSettings());//首次序列化前可能为null，自动创建默认实例
}
