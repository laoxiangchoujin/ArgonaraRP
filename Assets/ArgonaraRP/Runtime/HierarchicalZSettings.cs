using UnityEngine;

//Hi-Z（分层深度图）的设置：挂在管线资产**顶层**的一份（不再放 SSR 里面）。
//它是被**消费**的资源 —— SSR 和 SSGI 都用它，"本帧要不要建"由消费它的特性决定
//（渲染器传 useSSR || useSSGI）⇒ 这里**没有**总开关。
[System.Serializable]
public class HierarchicalZSettings
{
    //mip 级数：越大远处跳得越快（顶级只剩几个像素就没意义了）。1080p 用 6 级：mip0 全分辨率、顶级 30×17
    [Range(2, 12)] public int mipCount = 6;

    //HiZ用的shader（HierarchicalZ.shader）：mip0 那一趟 + 逐级降采样。
    //放在这个类里而不是管线asset顶层：它只服务于 HiZ 这一个特性，跟着 HiZ 的设置一起走（和 SSRSettings 一个套路）
    [SerializeField]
    Shader shader = default;

    //渲染时才创建材质、隐藏、不保存（和 SSRSettings / PostFXSettings 一个套路）；材质不能序列化
    [System.NonSerialized]
    Material material;

    public Material Material
    {
        get
        {
            if (material == null && shader != null)
            {
                material = new Material(shader);
                material.hideFlags = HideFlags.HideAndDontSave;
            }
            return material;
        }
    }
}
