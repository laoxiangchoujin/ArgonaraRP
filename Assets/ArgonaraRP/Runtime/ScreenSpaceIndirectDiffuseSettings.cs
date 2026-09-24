using UnityEngine;

//屏幕空间间接光（SSGI）的设置。参数分四组：追踪 / 时间累积 / 空间滤波 / 合成与调试。
//⚠️ Hi-Z 不在这里：它是管线资产**顶层**的独立设置（`hiz`），SSR / SSGI 共用同一份（没必要建两份）。
[System.Serializable]
public class ScreenSpaceIndirectDiffuseSettings
{
    //总开关：关掉时渲染器既不建 GI 图、也不画那几趟，等于完全不存在
    public bool enabled = false;

    //追踪分辨率：关 = 半分辨率（默认，省 4 倍像素）；开 = 全分辨率（GI 的细节上限翻倍、串色少一半）。
    //⚠️ 翻转会**重建**那两张跨帧持久图（尺寸变了），显存/带宽、trace 像素数、两趟双边都是 ×4；
    //   而且 blurRadius 的单位是"GI 图的纹素"⇒ 全分辨率下同样的半径只盖一半的屏幕范围。
    [Tooltip("全分辨率追踪：关=半分辨率（快，默认）；开=GI 细节上限翻倍，但显存/带宽和追踪像素数都 ×4")]
    public bool fullResolution = false;

    //=============================== 追踪（trace）===============================
    [Header("追踪设置")]
    //每个像素打几条半球射线：越多噪点越少、越贵（剩下的噪点交给时间累积 + 双边滤波）
    [Range(1, 16)] public int rayCount = 3;

    //射线最长走多远（视空间米）：太短会丢大范围的 GI，太长容易漏光、也慢
    [Range(1f, 100f)] public float rayLength = 20f;

    //步数上限：Hi-Z 是大步跳的（安全就升档、碰到就退档），一般不需要很大
    [Range(8, 512)] public int stepCountLimit = 48;

    //命中厚度（视空间米）：判"这一步是否真的穿过了表面"。太小会漏交（成片断带），太大就把更远的背景也算成命中（漏光）
    [Range(0.001f, 2f)] public float thickness = 0.15f;

    //屏幕边缘淡出：屏幕外没有信息 ⇒ 越靠屏幕边 GI 越淡（0 = 不淡）
    [Range(0f, 0.5f)] public float screenFade = 0.05f;

    //命中点参与着色的**其他光源**（点光/聚光）最大数量：0 = 不参与（命中点只用主光）。
    //挑的是**离命中点最近的**这几盏（先扫一遍所有灯只算距离平方，超出灯范围的直接跳过）。
    //⚠️ 每盏都要算 range/spot 衰减 + 一次阴影采样 ⇒ 越大越贵（默认 2 够用）
    [Range(0, 8)] public int otherLightLimit = 2;

    //=============================== 采样噪声（STBN 时空蓝噪声图集）===============================
    //512×512 的 2D 图集 = 8×8 个 64×64 切片（= 64 帧）：每帧用一片 ⇒ 半球方向"每像素、每帧"都错开。
    //比纯程序化的 R2 序列更均匀（空间上是蓝噪声、相邻帧也错开）⇒ TAA/时间累积收敛更快。
    //**留空 = 退回程序化的"R2 + 每像素相位"**（方便 A/B 对比，不会报错）。
    //⚠️ 这张图的导入设置必须是：**sRGB 关、Filter=Point、Wrap=Repeat、不压缩、无 mip**（错一条就毁掉分布）。
    //寻址（见 shader）：slice = 帧序号 % 64；tile = (slice % 8, slice / 8)；uv = (tile*64 + pixelPos % 64 + 0.5) / 512
    [Tooltip("STBN 时空蓝噪声图集（留空则用程序化 R2 序列）")]
    public Texture2D blueNoise = default;

    //=============================== 时间累积（Temporal）===============================
    [Header("时间累积")]
    //历史权重：越大越稳（噪声收敛快）、越容易拖影。
    //⚠️ 我们**没有运动矢量**，时间累积靠"深度 + 上一帧 VP"重投影 ⇒ 动的物体会拖，别给太高
    [Range(0f, 0.99f)] public float temporalWeight = 0.9f;

    //AABB 截断的缩放：越大历史越宽松（更稳、更容易鬼影）
    [Range(1f, 5f)] public float temporalScale = 1.25f;

    //"重投影位移越大越信当前帧"的放大系数（和 TAA 那个同名，一个意思）。
    //⚠️ 我们**没有运动矢量**：这里的位移不是"物体在动"，而是"相机移动造成的重投影位移"，
    //   而深度重投影在相机移动时是**准的** ⇒ 这个系数本质是"没 MV 时的代偿"，给大了会
    //   "相机一动就把历史权重打到 1"（= 每帧只剩那几条射线、零累积 ⇒ 大片噪点）。
    //   0 = 完全不惩罚（移动时照样累积，最不噪；代价：真在动的物体会更容易拖影）
    [Range(0f, 200f)] public float motionBlendScale = 10f;

    //=============================== 空间滤波（双边）===============================
    [Header("空间滤波")]
    //双边滤波半径（像素）：越大越平滑、越容易丢细节
    [Range(2f, 12f)] public float blurRadius = 6f;

    //=============================== 合成 & 调试 ===============================
    [Header("合成和调试")]
    //间接光亮度倍率（gain）：1 = 原样
    [Range(0f, 8f)] public float intensity = 1f;

    //调试：只输出间接光（不叠回场景）—— 看 GI 本身是否合理
    public bool debugIndirect = false;

    //SSGI 用的 shader（ScreenSpaceIndirectDiffuse.shader）：追踪 + 时间累积 + 横竖两趟双边，
    //靠 pass 索引被 DrawProcedural 调用。放在设置类里（跟这个特性一起走，和 SSR / PCSS 一个套路）
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
