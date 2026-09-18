using UnityEngine;

[System.Serializable]
public class SSRSettings
{
    //总开关：关掉时渲染器既不创建SSR的RT、也不画SSR，等于完全不存在
    public bool enabled = false;

    //追踪分辨率：关 = 半分辨率（默认，省 4 倍像素）；开 = 全分辨率。
    //反射内容的分辨率上限就由它决定（半分辨率时高频边缘必然是 2 像素级台阶，亚像素细化也救不回来）。
    //⚠️ 翻转会**重建**两张跨帧反射图 + 本帧的 blur 倒手图，而且显存/带宽、trace 的像素数都是 ×4。
    [Tooltip("全分辨率追踪：关=半分辨率（快，默认）；开=反射内容更细，但反射图显存/带宽和 trace 像素数都 ×4")]
    public bool fullResolution = false;

    //=============================== 追踪（trace）===============================
    [Header("追踪设置")]
    //射线总长（视空间米）：没碰到东西就在这个长度内一直步进
    [Range(0.1f, 200f)] public float totalRayLength = 32f;
    //每步跨多少屏幕像素：越大越快、越容易漏交
    [Range(0.5f, 8f)] public float pixelStride = 4f;
    //步数上限：防止 stride 设得太小时步数爆炸（一般不会）
    [Range(8, 256)] public int stepCountLimit = 64;
    //近处放宽步长的生效距离（米）：表面离相机越近步长越宽（最多×2），超过它按基准步长走
    [Range(1f, 500f)] public float nearStepBoldenRange = 100f;
    //深度厚度（视空间米）：判交用的"物体有多厚"。太小会断带（一步跨过整个物体），太大会把更远的背景也算成命中
    [Range(0.0001f, 5f)] public float pixelThickness = 0.15f;

    //=============================== 命中后的淡出（alphaCalc）===============================
    [Header("命中后的淡出和强度")]
    //反射方向朝相机时的淡出宽度：viewZ≤0 全亮，越朝相机飞来(viewZ越正)越淡，到该值时完全消失
    [Range(0.01f, 1f)] public float backRayFadeWidth = 0.2f;
    //屏幕边缘淡出的起点：屏幕中心=0、边缘=1 的归一化半径，超过它开始淡出，到边缘正好淡到 0
    [Range(0.5f, 0.99f)] public float screenEdgeFadeStart = 0.9f;
    //命中点越靠射线末端越淡的强度：0=完全不衰减，1=原来的效果
    [Range(0f, 1f)] public float marchFadeStrength = 1f;

    //（原版还有个 _SSRReflectionRoughness：那是环境反射fallback用的粗糙度。本项目的合成放在接收面/水面，
    //  所以那个参数归接收面自己管，不在这里）

    //=============================== 合成 & 质量 ===============================
    //SSR反射的亮度倍率（gain）：0 = 反射全黑，1 = 原样，>1 = 更亮。
    //只乘反射颜色；"要不要用SSR"不受它影响（那由可信度a和总开关决定）
    [Tooltip("SSR反射亮度倍率（gain）：0=反射全黑，1=原样，>1=更亮（半分辨率+模糊会摊平高光，可以在这补一点）")]
    [Range(0f, 5f)] public float intensity = 1f;

    //消萤火虫（firefly）：那两趟blur的权重再乘一个"按亮度反向"的 w = 1/(Luminance+1)
    //（卡特莱克 bloom 的 fade fireflies 那招）⇒ 孤立的高亮命中点（如单点命中太阳高光）被邻居平均掉。
    //关掉 = 纯二项式模糊（改动前的行为，零成本开关，只是个 uniform）
    [Header("消除ssr萤火虫")]
    [Tooltip("消除 SSR 萤火虫：blur 改用按亮度反向加权，把孤立的高亮命中点压掉；关掉 = 纯二项式模糊")]
    public bool fireflySuppression = true;

    //压亮度的强度 k：权重 w = 1/(Luminance*k + 1)。
    //0 = 完全不压（等价于把上面开关关掉）、1 = 卡特莱克那版原式、越大压得越狠（反射越容易发闷）
    [Tooltip("消萤火虫的强度 k：w = 1/(Luminance*k + 1)。0=不压、1=原式、越大压得越狠（觉得反射发闷就往小拖）")]
    [Range(0f, 5f)] public float fireflyStrength = 0.5f;

    //=============================== 粗糙度 → mip（反射色采样颜色快照的 mip）===============================
    //反射颜色按"接收面粗糙度"取颜色快照的 mip 级：越粗糙采越糊的一级 ⇒ 命中点抖动/高光闪点被平均掉。
    //lod = scale * roughness + bias。lod 的有效上限 = 颜色快照的 mip 级数 - 1
    //（级数在 CameraBufferSettings.copyColorMipCount：8 级 ⇒ lod 最大 7；mip 没开时这两项无意义）
    [Header("ssr颜色纹理mip采样参数")]
    [Tooltip("粗糙度→mip 的斜率：rough=1 时采到哪一级。取『级数-1』表示最粗糙正好采最糊那级（8级就填7）；太糊就按观感往回收，常用 4~5")]
    [Range(0f, 10f)] public float roughnessMipScale = 5f;
    [Tooltip("粗糙度→mip 的整体平移：正=更糊、负=更清。微调用，一般 0")]
    [Range(-3f, 3f)] public float roughnessMipBias = 0f;

    //=============================== Hi-Z（分层深度图）===============================
    //SSR 的追踪靠它决定步长（安全就升 mip、碰到就退一级）。
    //挂在 SSR 设置里而不是管线asset顶层：目前只有 SSR 用它；以后 SSAO 等也要用时再往上提。
    public HierarchicalZSettings hiz = new HierarchicalZSettings();

    //SSR用的shader（ScreenSpaceReflection.shader）：追踪 + 两趟模糊，靠pass索引被DrawProcedural调用。
    //放在这个类里而不是管线asset顶层：它只服务于SSR这一个特性，跟着SSR的设置一起走（PCSS那个同理）
    [SerializeField]
    Shader shader = default;

    //渲染时才创建材质、隐藏、不保存（和 PostFXSettings 一个套路）；材质不能序列化
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
