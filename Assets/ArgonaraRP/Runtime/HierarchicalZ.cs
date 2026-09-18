using UnityEngine;
using UnityEngine.Rendering;

///分层深度图（Hi-Z）：把深度图做成一条 mip 链，每级的一个纹素 = 上一级 2×2 块里**离相机最近**的那个深度
///（ReverseZ 下是取 max）。屏幕空间追踪（SSR 等）用它按 mip 级决定步长：
///没碰撞 ⇒ mip+1、步长翻倍；碰到 ⇒ 退一步、mip-1；mip0 再用厚度确认命中。
///⇒ 比线性步进快得多，而且"没碰撞"这个结论永远可靠（2×2 取最近 = 保守，不会漏）。
///
///主图**跨帧常驻**（只在尺寸/级数变了才重建）：内容虽然每帧全重写，但"自己 new 的图一定有那条 mip 链、
///格式/过滤自己说了算"，比向 Unity 的临时 RT 池要一张更可控（尤其我们还要往它的各级 mip 里拷数据）。
public class HierarchicalZ
{
	//=========================== 全局 uniform ===========================
	//（名字要和 HierarchicalZ.shader 里的一致；前两个也是给追踪那趟用的）
	static int
		hiZTexId = Shader.PropertyToID("_HiZTex"),//主图（带 mip 链）：trace 直接按 mip 采它
		maxMipLevelId = Shader.PropertyToID("_MaxHiZMipLevel"),//trace 里 clamp mip 级用
		sourceMipLevelId = Shader.PropertyToID("_HiZSourceMipLevel"),//降采样那趟：源级
		sourceTexelSizeId = Shader.PropertyToID("_HiZSourceTexelSize"),//降采样那趟：源级纹素尺寸 (1/w, 1/h, w, h)
		enabledId = Shader.PropertyToID("_HiZEnabled");//追踪那趟：本帧 HiZ 可不可用（0/1），不可用时它退回线性步进

	//=========================== 每级一张的临时图 ===========================
	//降采样那趟的源和目标必须是**两张不同的图**（同一张既当纹理又当渲染目标，D3D 上会读到 0 —— 实测过），
	//所以每级借一张单级临时图，算完再整条 CopyTexture 进主图 ⇒ 主图自己从头到尾都不当渲染目标。
	//id 是**连续分配**的：这里一次性把 _HiZTemp0..N 都申请一遍，之后用第一个 id + i 取第 i 级（和 PostFXStack 的 _BloomPyramid 一个写法）
	private const int maxMipCount = 12;//和 HierarchicalZSettings.mipCount 的 Range 上限一致
	static int hiZTempId;

	static HierarchicalZ ()
	{
		hiZTempId = Shader.PropertyToID("_HiZTemp0");
		for (int i = 1; i < maxMipCount; i++)
		{
			Shader.PropertyToID("_HiZTemp" + i);
		}
	}

	//=========================== 常驻资源 ===========================
	//精度较高的主图：它同时就是 mip0（= 深度图同分辨率的单通道浮点版），mip 链就是 Hi-Z 金字塔
	RenderTexture hiZTexture;
	//上一次是按什么尺寸/级数建的主图（⚠️ 判断"要不要重建"不能拿 rt.format 之类去比：
	//请求的格式和平台解析出来的具体格式不相等 ⇒ 每帧都判定"变了" ⇒ 每帧销毁重建）
	int hiZWidth, hiZHeight, hiZMipCount;
	Material material;//本帧要画的材质（Setup 时从 HierarchicalZSettings 拿；Draw 用它画那两趟，Dispose 负责销毁）

	//HierarchicalZ.shader 里的 pass 顺序（**必须和 shader 里 Pass 的先后完全一致**）
	private enum Pass
	{
		Mip0,      //0：深度图 → mip0（1:1 转格式，不能 CopyTexture 直接拷）
		Downsample,//1：上一级 2×2 取最近深度 → 当前级
	}

	///每帧：（按需）建/重建带 mip 链的主图 + 上传 _MaxHiZMipLevel。
	///**每帧都调**（和 ssr.Setup 一起就行）：它只建图 + 传参数，不碰渲染目标，所以放哪都行；
	///"要一张完整深度图"是 Draw 那边的事。
	///use = 本帧要不要 HiZ（渲染器给：比如"SSR 开着"）；为假或没配 shader 时在这里就把主图放了
	///（省显存），并把 _HiZTex 绑成 1×1 黑图兜底（深度 0 = 无穷远 ⇒ 追踪永远不会认为"碰到了"，
	///也不会采到一张已经被销毁的图）。
	public void Setup (CommandBuffer buffer, HierarchicalZSettings settings, bool use,
		int screenWidth, int screenHeight)
	{
		if (!use || settings == null || !settings.enabled || settings.Material == null)
		{
			material = null;//让 Draw 早退
			//先解绑再销毁（同重建那条：_HiZTex 是跨帧绑定，销毁后它就成了"不存在的图"）；
			//顺便把 1×1 黑图当兜底：深度 0 = 无穷远 ⇒ 追踪永远不会认为"碰到了"（也不会空引用）
			buffer.SetGlobalTexture(hiZTexId, Texture2D.blackTexture);
			ReleaseTexture();//关掉了就把它放了：省显存
			buffer.SetGlobalInt(maxMipLevelId, 0);
			buffer.SetGlobalFloat(enabledId, 0f);//追踪那趟据此退回线性步进（黑图会让 Hi-Z 永远不命中）
			return;
		}
		material = settings.Material;//本帧要画的材质（Draw 用它画那两趟，Dispose 负责销毁）

		screenWidth = Mathf.Max(1, screenWidth);
		screenHeight = Mathf.Max(1, screenHeight);

		//级数：设置里的值，但不超过"这条 mip 链本身的上限"（1×1 那一级之后就没有更高级了），
		//也不超过临时图 id 的分配数量
		int mipCountLimit = Mathf.FloorToInt(Mathf.Log(Mathf.Max(screenWidth, screenHeight), 2f)) + 1;
		int mipCount = Mathf.Clamp(settings.mipCount, 1, Mathf.Min(mipCountLimit, maxMipCount));

		if (hiZTexture == null ||
		    hiZWidth != screenWidth || hiZHeight != screenHeight || hiZMipCount != mipCount)
		{
			//先解绑再销毁：_HiZTex 是**跨帧**的全局绑定（上一帧 Draw 末尾绑的主图），
			//不然从"销毁旧图"到"本帧 Draw 重新绑"这段时间里，它指着一张已经不存在的图
			buffer.SetGlobalTexture(hiZTexId, Texture2D.blackTexture);
			ReleaseTexture();
			hiZWidth = screenWidth;
			hiZHeight = screenHeight;
			hiZMipCount = mipCount;

			//单通道 32 位浮点：只存深度，精度要够（半精度的深度在远处会糊到一起）
			hiZTexture = new RenderTexture(screenWidth, screenHeight, 0,
				RenderTextureFormat.RFloat, RenderTextureReadWrite.Linear)
			{
				name = "_HiZTex",
				hideFlags = HideFlags.HideAndDontSave,
				//我们不糊它：取邻居时要精确命中原纹素
				filterMode = FilterMode.Point,
				//屏幕边缘的块凑不满 4 个邻居，钳制即可（文章里也是 Clamp）
				wrapMode = TextureWrapMode.Clamp,
				//整条 mip 链都在这张图里（各级由 Draw 从临时图 CopyTexture 进来）
				useMipMap = true,
				//mip 由我们自己"2×2 取最近"生成，不让硬件自动生成（自动生成是**平均**，会破坏保守性）
				autoGenerateMips = false,
			};
			hiZTexture.Create();
			//不用清图：Draw 每帧都会把 mip0..N-1 全写一遍（没写的那几级超过 _MaxHiZMipLevel，追踪采不到）
		}

		//给追踪那趟：可用的最高 mip 级（超过它就没数据了）+ "可用"这个开关
		buffer.SetGlobalInt(maxMipLevelId, mipCount - 1);
		buffer.SetGlobalFloat(enabledId, 1f);
	}

	///每帧：深度图 → mip0，再逐级降采样到 mip 1..N-1（两趟都在 HierarchicalZ.shader 里）。
	///做法：**全程在临时图上算**（每级一张单级临时图），算完整条 CopyTexture 进主图的各级 ——
	///主图自己**只被拷、不当渲染目标** ⇒ 不会出现"同一张图既读又写"（D3D 上会读到 0，实测过）。
	///**不需要单独的 Cleanup**：临时图在末尾一起还，主图跨帧常驻、只在 Dispose 里放。
	///⚠️ 会把渲染目标改到临时图 ⇒ 调用方之后自己设 RT（SSR 的 Draw 本来就会设）。
	public void Draw (CommandBuffer buffer)
	{
		if (material == null || hiZTexture == null)//Setup 里没建（关掉了 / 没材质）⇒ 什么都不画
		{
			return;
		}

		//帧调试器是按"命令缓冲区的名字"给每次执行分组的：不改名字的话这几趟会挂在上一段下面
		//（和 SSR 一样：这里改完不还，调用方画别的东西时自己恢复）
		buffer.name = "Hierarchical Z";
		buffer.BeginSample("Hierarchical Z");

		//1.借 N 张单级临时图：每级尺寸都不同，所以各借一张（末尾一起还）。
		//  GetTemporaryRT 只是往命令缓冲里录一条"要一张这样的图"，真正分配走 Unity 的临时 RT 池，很便宜。
		for (int i = 0; i < hiZMipCount; i++)
		{
			buffer.GetTemporaryRT(hiZTempId + i, Mathf.Max(1, hiZWidth >> i), Mathf.Max(1, hiZHeight >> i),
				0, FilterMode.Point, RenderTextureFormat.RFloat, RenderTextureReadWrite.Linear);
		}

		//这几趟都**整屏覆盖**，所以：
		//  LoadAction=DontCare：旧像素马上被全部盖掉 ⇒ 不用把旧内容读回来（省一次全屏读）
		//  StoreAction=Store：结果后面还要用（CopyTexture 要读它）⇒ 必须写回显存
		//
		//2.mip0：深度图 → temp0，再拷进主图 mip0（1:1、其实只是转格式）
		buffer.SetRenderTarget(hiZTempId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
		buffer.DrawProcedural(Matrix4x4.identity, material, (int)Pass.Mip0, MeshTopology.Triangles, 3);
		buffer.CopyTexture(hiZTempId, 0, 0, hiZTexture, 0, 0);

		//3.逐级降采样：源 = 上一级临时图（绑成 _HiZTex），目标 = 本级临时图，再拷进主图 mip i。
		//  每一级都把"上一级"的 2×2 取最近 ⇒ 级数越高，"这一块里最近的表面"越近（越保守）
		buffer.SetGlobalInt(sourceMipLevelId, 0);//源是单级临时图 ⇒ lod 恒为 0
		for (int i = 1; i < hiZMipCount; i++)
		{
			int sourceWidth = Mathf.Max(1, hiZWidth >> (i - 1));//源 = 上一级
			int sourceHeight = Mathf.Max(1, hiZHeight >> (i - 1));
			buffer.SetGlobalTexture(hiZTexId, hiZTempId + i - 1);//注意：绑的是**临时图**，不是主图
			buffer.SetGlobalVector(sourceTexelSizeId,
				new Vector4(1f / sourceWidth, 1f / sourceHeight, sourceWidth, sourceHeight));//±0.5 个源纹素用它

			buffer.SetRenderTarget(hiZTempId + i, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
			buffer.DrawProcedural(Matrix4x4.identity, material, (int)Pass.Downsample, MeshTopology.Triangles, 3);
			buffer.CopyTexture(hiZTempId + i, 0, 0, hiZTexture, 0, i);
		}

		//4.整条链都进主图了，这才把 _HiZTex 绑给追踪那趟（主图全程没当过渲染目标，这里绑上就不会再被覆盖）
		buffer.SetGlobalTexture(hiZTexId, hiZTexture);

		//5.临时图一起还（本帧不再用）
		for (int i = 0; i < hiZMipCount; i++)
		{
			buffer.ReleaseTemporaryRT(hiZTempId + i);
		}

		buffer.EndSample("Hierarchical Z");
	}

	///释放这个类持有的东西（渲染器 Dispose 时调）：主图 + 材质
	public void Dispose ()
	{
		ReleaseTexture();
		CoreUtils.Destroy(material);
		material = null;
	}

	///释放主图（重建时、关掉时、以及 Dispose 时用）
	private void ReleaseTexture ()
	{
		if (hiZTexture != null)
		{
			hiZTexture.Release();
			CoreUtils.Destroy(hiZTexture);
			hiZTexture = null;
		}
	}
}
