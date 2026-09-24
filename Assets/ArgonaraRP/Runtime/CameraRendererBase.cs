using UnityEngine;
using UnityEngine.Rendering;

public abstract class CameraRendererBase
{
	public abstract void Render(ScriptableRenderContext context, Camera camera, CameraBufferSettings bufferSettings,
		bool useDynamicBatching, bool useGPUInsancing, bool useLightsPerObject,
		ShadowSettings shadowSettings, SSRSettings ssrSettings, PostFXSettings postFXSettings, int colorLUTResolution,
		TemporalAntiAliasingSettings taaSettings, ScreenSpaceIndirectDiffuseSettings ssgiSettings,
		HierarchicalZSettings hizSettings);

	public abstract void Dispose();

	///外部要求"下一帧丢掉历史"（例如切场景：相机没动但画面全换了，靠瞬移判定抓不到）。
	///由管线在场景事件里调；目前只有 TAA 需要它。
	public abstract void RequestResetHistory();


	//=========================== 颜色快照的 mip 链 ===========================
	//两个渲染器拷颜色的时机不同（前向一次、延迟两次），但"建几级 / 怎么建"必须完全一致，所以统一放这里。

	///按设置算出颜色快照要建几级 mip（含 mip0）：返回值 1 = 不建链（等价于只有 mip0，行为同以前）
	public static int GetColorMipCount(CameraBufferSettings bufferSettings, int width, int height)
	{
		if (!bufferSettings.copyColorMips)
		{
			return 1;
		}
		//分辨率本身能容纳的级数：1080p 是 1 + log2(1920) = 11 级。
		//填多了 Unity 会忽略，不如自己夹掉；顺便把"字段还没被序列化过（= 0）"也一起兜成 1 = 不建链
		int naturalMipCount = 1 + Mathf.FloorToInt(Mathf.Log(Mathf.Max(width, height), 2f));
		return Mathf.Clamp(bufferSettings.copyColorMipCount, 1, naturalMipCount);
	}

	///创建"给shader读"的颜色快照。mipCount <= 1 时走老的那句（行为一字未变）；
	///要 mip 就必须用 RenderTextureDescriptor 那套重载 —— 老的 int 重载给不了 mip。
	public static void CreateReadableColorTexture(CommandBuffer buffer, int nameId,
		int width, int height, bool useHDR, int mipCount)
	{
		RenderTextureFormat format = useHDR ? RenderTextureFormat.DefaultHDR : RenderTextureFormat.Default;
		if (mipCount <= 1)
		{
			buffer.GetTemporaryRT(nameId, width, height, 0, FilterMode.Bilinear, format);
			return;
		}

		var descriptor = new RenderTextureDescriptor(width, height, format, 0)
		{
			//顺序有讲究：useMipMap 的 setter 内部会去改 mipCount（true = 整条链），所以先写它、再写 mipCount
			useMipMap = true,
			//别让Unity在每次写入之后自动生成mip：光照Pass那几次写也会顺带跑一遍，纯浪费；时机我们自己控
			autoGenerateMips = false,
			mipCount = mipCount,
			//和老的 int 重载（RenderTextureReadWrite.Default）口径对齐：非HDR的颜色格式按项目色彩空间决定要不要sRGB转换
			//（本项目是Linear → 要），HDR(float)格式一律线性
			sRGB = !useHDR && QualitySettings.activeColorSpace == ColorSpace.Linear,
			msaaSamples = 1,//临时图历来不开MSAA（老重载也没有），显式写死免得跟全局设置跑
		};
		//有mip时用Trilinear：按LOD采样时才在两级mip之间平滑过渡（Bilinear是"点着"挑一级，会有台阶）
		buffer.GetTemporaryRT(nameId, descriptor, FilterMode.Trilinear);
	}

	
}
