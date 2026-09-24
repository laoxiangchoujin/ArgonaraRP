using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

//时域抗锯齿（TAA）：抖动投影矩阵 + 混合当前帧和历史帧。先做"仅重投影"版（不写运动矢量）。
//四个阶段由渲染器调（同 ScreenSpaceReflection / HierarchicalZ）：Setup / Draw / Cleanup / Dispose。
//⚠️ 历史图要跨帧 ⇒ 必须持久 RT（不能用 GetTemporaryRT）；尺寸一律用 bufferSize（不是 Screen）。
//⚠️ 状态是**每个相机一份**：同一个渲染器实例会被多台相机**轮流**调用（Game 视图 + Scene 视图 + …），
//   共用一份历史的话它们会互相把对方刚画的那帧当成"上一帧"（再叠加"这帧没跑就释放"⇒ 每帧白重建）。
public class TemporalAntiAliasing
{
	//=============== 一台相机的全部跨帧状态 ===============
	sealed class CameraState
	{
		//两张跨帧持久的历史图（双缓冲）：本帧读 [readIndex]、写另一张
		public RenderTexture[] historyTextures = new RenderTexture[2];
		public int readIndex;
		public int width, height;//上次按什么建的（变了才重建）
		public bool hdr;

		//重投影
		public Matrix4x4 currentViewProjection;//本帧 VP（Cleanup 时挪进 previous）
		public Matrix4x4 previousViewProjection;//上一帧 VP（shader 重投影用它）
		public bool hasHistory;//历史里真的存过东西（没存过 ⇒ 这帧必须重置）

		//抖动
		public int jitterIndex;//8 帧 Halton 循环：用 (jitterIndex + 1) & 7 推进
		public Vector2 jitter;//本帧抖动（UV 单位）
		public Matrix4x4 jitteredProjection;//本帧抖动后的投影矩阵

		public bool resetHistory = true;//这帧不混合历史

		//最后一次被哪一帧用到（用来回收"不再渲染的相机"：Scene 视图窗口关了、临时相机用一次就没了的）
		public int lastUsedFrame = -1;
	}

	//"相机 → 它的状态"这一对。
	//用 List 而不是 Dictionary：键（相机）可能被销毁，Unity 的 `==` 能识别"假 null"，数量也就一两台。
	sealed class Entry
	{
		public Camera camera;
		public CameraState state;
	}

	Material material;//本帧要画的材质（Setup 时从 settings 拿；Dispose 负责销毁）
	List<Entry> entries = new List<Entry>();

	//某台相机连续多少帧没渲染就算"不用了"，回收它的历史图（约 1 秒；见 GetState 里的说明）
	const int stateKeepFrames = 60;

	static int
		historyTexId = Shader.PropertyToID("_HistoryTex"),
		taaTexelSizeId = Shader.PropertyToID("_TAATexelSize"),
		jitterId = Shader.PropertyToID("_TAAJitter"),
		resetHistoryId = Shader.PropertyToID("_TAAResetHistory"),
		prevViewProjId = Shader.PropertyToID("_TAAPrevViewProj"),
		blendFactorId = Shader.PropertyToID("_TAABlendFactor"),
		motionBlendScaleId = Shader.PropertyToID("_TAAMotionBlendScale"),
		sharpenStrengthId = Shader.PropertyToID("_TAASharpenStrength"),
		//本帧颜色（全屏 pass 的输入，和 PostFXStack 同一套命名）
		sourceTexId = Shader.PropertyToID("_SourceTexture");
	//（深度不用 C# 绑：shader 直接采项目那份**可读的** _CameraDepthTexture 拷贝，见 Draw 里的说明）

	private enum Pass { Taa }//和 shader 里 Pass 的先后一致

	public TemporalAntiAliasing () { }

	//=========================== 判定 / 状态查找 ===========================

	///本帧走不走 TAA 的**公共判定**（和 SSR 一个套路：总开关 + 配了 shader + 相机类型合适）
	public static bool ShouldRender (TemporalAntiAliasingSettings settings, Camera camera)
	{
		return settings != null && settings.enabled && settings.Material != null && IsEligible(camera);
	}

	///哪些相机**不跑** TAA（也**不许碰状态**）：
	///  · 反射相机：一台相机要出 cubemap 六个面 ⇒ 六面会互相把对方当成"上一帧"（而且抖动对探针没有意义）；
	///  · 预览相机：编辑器里临时渲染（材质预览、缩略图等），别为它一直占两张全屏图。
	///其余（Game 视图、Scene 视图、以及以后的多相机）各自有各自的 state ⇒ 互不干扰。
	static bool IsEligible (Camera camera)
	{
		return camera != null &&
		       camera.cameraType != CameraType.Reflection &&
		       camera.cameraType != CameraType.Preview;
	}

	///拿这台相机的状态；没有就新建（新建的 state 里 resetHistory 初值就是 true ⇒ 天然是"首帧要重置"）。
	///顺手回收两种"不再需要"的条目：**相机被销毁**的、以及**很久没渲染**的（Scene 视图窗口关掉、一次性相机等）。
	///⚠️ 宽限期取 1 秒左右而不是 1 帧：Scene 视图/Game 视图偶尔跳帧（编辑器按需重绘）不能算"不用了"，
	///   否则历史会被反复丢掉重建（那就是 TAA 永远攒不起来的老毛病）。
	CameraState GetState (Camera camera)
	{
		int frame = Time.frameCount;
		for (int i = 0; i < entries.Count; i++)
		{
			CameraState state = entries[i].state;
			//相机被销毁过（Unity 的 == 会把"假 null"判成 null）、或者超过宽限期没被用过 ⇒ 释放它的两张图
			if (entries[i].camera == null || frame - state.lastUsedFrame > stateKeepFrames)
			{
				ReleaseState(state);
				entries.RemoveAt(i--);
				continue;
			}
			if (entries[i].camera == camera)
			{
				state.lastUsedFrame = frame;
				return state;
			}
		}

		Entry entry = new Entry { camera = camera, state = new CameraState { lastUsedFrame = frame } };
		entries.Add(entry);
		return entry.state;
	}

	///只查不建（Draw / Cleanup 用：状态不存在说明这帧压根没走 Setup）
	CameraState FindState (Camera camera)
	{
		for (int i = 0; i < entries.Count; i++)
		{
			if (entries[i].camera == camera)
			{
				return entries[i].state;
			}
		}
		return null;
	}

	//=========================== 四个阶段 ===========================

	public void Setup (CommandBuffer buffer, TemporalAntiAliasingSettings settings, bool use,
		Camera camera, int screenWidth, int screenHeight, bool hdr, Matrix4x4 viewProjection)
	{
		if (!IsEligible(camera))
		{
			//被排除的相机（反射/预览）**什么都不能碰**：它们每帧也会走到这里
			return;
		}

		if (!use || settings == null || settings.Material == null)
		{
			//真的关掉 TAA（总开关关 / 没配 shader）⇒ 所有相机的历史都丢掉，重新开起来时重建
			material = null;
			ReleaseAllStates();
			return;
		}

		material = settings.Material;
		CameraState state = GetState(camera);
		AllocateTextures(buffer, state, screenWidth, screenHeight, hdr);

		state.currentViewProjection = viewProjection;
		if (NeedResetHistory(state, viewProjection))
		{
			state.resetHistory = true;
		}

		//⚠️ 这里**不再**推进 jitter：它必须在 `SetupCameraProperties` 之前算（渲染器调下面的
		//   GetJitteredProjection），放到这里就晚了、而且会一帧推进两次。
		SetParameters(buffer, state, settings);
	}

	///本帧的抖动投影矩阵：渲染器在 `context.SetupCameraProperties(camera)` **之前**把它赋给 camera.projectionMatrix。
	///为什么必须在之前：SetupCameraProperties 就是拿 camera.projectionMatrix 去算 unity_MatrixVP 的；
	///写在之后就得自己改全局矩阵，还会和 unity_MatrixInvVP 打架。
	///⚠️ 帧末渲染器必须把 camera.projectionMatrix 还原（否则抖动一帧帧累积）。
	public Matrix4x4 GetJitteredProjection (Camera camera, int screenWidth, int screenHeight)
	{
		CameraState state = GetState(camera);
		UpdateJitter(state, camera, screenWidth, screenHeight);
		return state.jitteredProjection;
	}

	///本帧抖动量（**UV 单位**，就是上传给 shader 的 `_TAAJitter`）。`GetJitteredProjection` 之后调才有本帧的值。
	///给别的屏幕空间特性复用：**凡是"用深度重投影查历史"的，都要和 TAA 一样把本帧抖动加回去**
	///（历史 UV 是从"未抖动的上一帧 VP"投出来的 ⇒ 天然带一个 −j；不加回来就等于每帧去偏了半个像素的位置采历史）。
	public Vector2 GetJitterUV (Camera camera)
	{
		CameraState state = FindState(camera);
		return state != null ? state.jitter : Vector2.zero;
	}

	///本帧那一趟：**本帧颜色（_SourceTexture）+ 上一帧历史（_HistoryTex）→ 写进"另一张"历史图**，
	///再把结果 **blit 回颜色附件**（后处理 / DrawFinal 接着用），最后交换双缓冲索引（在 Cleanup 里）。
	///colorAttachment / depthAttachment：调用方自己的附件 id（两侧名字不同，所以传进来）。
	///⚠️ 得传 camera：状态是每个相机一份（同一个渲染器实例被多台相机轮流用）。
	///⚠️ 调用方要紧接着 `ExecuteBuffer()`：后面（后处理 / DrawFinal）拿到的必须是**本帧混合后**的颜色；
	///   本趟改完 `buffer.name` **不还**（见函数内注释）⇒ 调用方在那句 ExecuteBuffer 之后再恢复。
	public void Draw (CommandBuffer buffer, Camera camera, RenderTargetIdentifier colorAttachment,
		RenderTargetIdentifier depthAttachment)
	{
		CameraState state = FindState(camera);
		if (material == null || state == null || state.historyTextures[0] == null)//Setup 里已经挡过一道，这里再兜一层
		{
			return;
		}

		//本帧写这张；另一张（state.readIndex 那张）是"上一帧的结果"，Setup 里已经绑给 _HistoryTex 了
		RenderTexture writeTexture = state.historyTextures[1 - state.readIndex];

		//帧调试器是按"命令缓冲区的名字"给每次执行分组的：不改名字的话这一趟会挂在上一段下面。
		//⚠️ 这里**不还**（和 SSR / HiZ / SSGI 一个惯例）：调用方紧接着 ExecuteBuffer，那一刻的名字就是外层组名；
		//   还回去会让 TAA 那一组被上一层（"Render Camera Deferred"）包住 ⇒ 由调用方在那句之后自己恢复。
		buffer.name = "Temporal Anti Aliasing";
		buffer.BeginSample("Temporal Anti Aliasing");

		//输入①：本帧颜色（后处理那套也叫 _SourceTexture）
		buffer.SetGlobalTexture(sourceTexId, colorAttachment);
		//输入②：本帧深度 —— 用项目里那份**可读的**深度拷贝 _CameraDepthTexture（渲染器已按 TAA 需要强制打开它）。
		//⚠️ 不直接绑深度附件当纹理：它这一帧还挂在附件上，同时又当纹理读是"SRV/DSV 冲突"（D3D 会告警、可能读到未定义值）。

		//1.混合：写进"写的那张"历史图（本帧结果 = 下一帧的历史）。
		//（这一趟只写颜色 ⇒ 深度附件照样接着、原样存回，别的 pass 不受影响；ZWrite Off 所以不会写它）
		buffer.SetRenderTarget(writeTexture, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
			depthAttachment, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);
		buffer.DrawProcedural(Matrix4x4.identity, material, (int)Pass.Taa, MeshTopology.Triangles, 3);

		//2.blit 回颜色附件：让后面的后处理 / DrawFinal 用上混合后的画面
		//（先写历史图再倒回来，是为了"历史图里存的永远是 TAA 自己的输出"，和 SSR 那两张持久图一个套路）
		buffer.Blit(writeTexture, colorAttachment);

		buffer.EndSample("Temporal Anti Aliasing");
	}

	///每帧末尾调（**在 Draw 之后**）：换双缓冲索引 + 把本帧 VP 存成"上一帧 VP" + 清 resetHistory。
	///⚠️ 顺序：`Setup` 里上传的是**上一帧**那份 VP（shader 重投影用），本帧跑完才把 current 挪进 previous。
	public void Cleanup (CommandBuffer buffer, Camera camera)
	{
		CameraState state = FindState(camera);
		if (state == null)//这帧没走 Setup（例如被相机类型挡了）⇒ 什么都没做
		{
			return;
		}

		//本帧写的那张，下一帧就是"上一帧的历史"（和 SSR 一样：交换只能在这做，AllocateTextures 里不能重置索引，否则永远不交换）
		state.readIndex = 1 - state.readIndex;
		//本帧 VP → 上一帧 VP（下一帧 Setup 上传它）
		state.previousViewProjection = state.currentViewProjection;
		state.hasHistory = true;
		//本帧已经混合过历史了（NeedResetHistory 设的标记是"这一帧"的，用完就清）
		state.resetHistory = false;

		//本帧**没有**需要归还的临时图：两张历史图是跨帧持久的（自己持有，不走 GetTemporaryRT），
		//这一趟也就"写历史图 + 倒回附件"两步、不需要倒手图。
		//（将来若要加"锐化/中间倒手"那种临时图，在这里 buffer.ReleaseTemporaryRT(...) —— 对照 HierarchicalZ.Draw 的结尾。）
	}

	///给外部用的"强制丢历史"（例如切场景、编辑器里手动重画、以后加"运动矢量不连续"的判定）：
	///**所有相机**下一帧只写当前帧、不混合历史。标记由 Cleanup 清掉。
	public void RequestResetHistory ()
	{
		for (int i = 0; i < entries.Count; i++)
		{
			entries[i].state.resetHistory = true;
		}
	}

	///释放这个类持有的东西（渲染器 Dispose 时调）：所有相机的持久历史图 + 那份材质。
	///（对照 ScreenSpaceReflection.Dispose / HierarchicalZ.Dispose 的写法）
	public void Dispose ()
	{
		ReleaseAllStates();
		//材质是 `TemporalAntiAliasingSettings` 惰性创建的那一份（两边引用同一个）：
		//销毁后 settings 里那个字段会变成"假 null"，下次取 Material 会自己重建 ⇒ 这里销毁是安全的
		CoreUtils.Destroy(material);
		material = null;
	}

	//=========================== 内部工具 ===========================

	//按需建/重建这台相机的两张历史图（尺寸或 HDR 变了才动手）；顺手清一次，免得第一帧采到垃圾
	//（清完渲染目标停在最后清的那张图上 ⇒ 调用方紧接着要画东西的话自己 SetRenderTarget 恢复）
	void AllocateTextures (CommandBuffer buffer, CameraState state, int screenWidth, int screenHeight, bool hdr)
	{
		bool needRebuild = state.historyTextures[0] == null ||
		                   state.width != screenWidth || state.height != screenHeight || state.hdr != hdr;
		if (!needRebuild)
		{
			return;
		}

		ReleaseState(state);
		state.width = screenWidth;
		state.height = screenHeight;
		state.hdr = hdr;
		state.readIndex = 0;
		state.resetHistory = true;//重建 ⇒ 上一帧的历史已经没了（尺寸/HDR 变也走这条）
		state.previousViewProjection = Matrix4x4.identity;//别拿旧尺寸下的 VP 去重投影
		state.hasHistory = false;

		RenderTextureFormat format = hdr ? RenderTextureFormat.DefaultHDR : RenderTextureFormat.Default;
		for (int i = 0; i < state.historyTextures.Length; i++)
		{
			state.historyTextures[i] = new RenderTexture(screenWidth, screenHeight, 0, format, RenderTextureReadWrite.Linear)
			{
				name = "_TAAHistory" + i,
				hideFlags = HideFlags.HideAndDontSave,
				filterMode = FilterMode.Bilinear,//历史要线性采样
				wrapMode = TextureWrapMode.Clamp,
				useMipMap = false,
				autoGenerateMips = false,
			};
			state.historyTextures[i].Create();
			buffer.SetRenderTarget(state.historyTextures[i], RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
			buffer.ClearRenderTarget(false, true, Color.clear);
		}
	}

	//释放一台相机的两张历史图（重建时、关掉时、相机被销毁时、以及 Dispose 时用）
	static void ReleaseState (CameraState state)
	{
		for (int i = 0; i < state.historyTextures.Length; i++)
		{
			if (state.historyTextures[i] != null)
			{
				state.historyTextures[i].Release();
				CoreUtils.Destroy(state.historyTextures[i]);
				state.historyTextures[i] = null;
			}
		}
	}

	void ReleaseAllStates ()
	{
		for (int i = 0; i < entries.Count; i++)
		{
			ReleaseState(entries[i].state);
		}
		entries.Clear();
	}

	//本帧抖动：8 帧一个循环，取 Halton(2,3) 序列上的一个点（低差异序列 ⇒ 8 帧铺得比随机均匀）
	//两种单位必须分清（差 2 倍，混了就变成"抖两个像素"）：
	//  · `jitter`（**UV 单位**）= (halton − 0.5) / 尺寸  ⇒ 上传给 shader，`uv -= _TAAJitter` 用
	//  · 投影矩阵里（**裁剪空间**）= (halton − 0.5) * 2 / 尺寸（NDC 跨 2，所以是上面那对的 2 倍）
	void UpdateJitter (CameraState state, Camera camera, int screenWidth, int screenHeight)
	{
		state.jitterIndex = (state.jitterIndex + 1) & 7;//0..7 循环（& 7 就是 %8），不会一帧帧越滚越大
		int i = state.jitterIndex + 1;//用第 1..8 个 Halton 点（第 0 个是 (0,0) ⇒ 等于没抖）
		float hx = Halton(i, 2) - 0.5f;//∈ [-0.5, 0.5)
		float hy = Halton(i, 3) - 0.5f;

		state.jitter = new Vector2(hx / screenWidth, hy / screenHeight);

		//裁剪空间平移矩阵（左乘 ⇒ clip.xy 各加 j*clip.w；透视/正交都对，不用去碰 w 那行）＝ Matrix4x4.Translate
		//⚠️ 在 GL.GetGPUProjectionMatrix **之前**加：y/z 翻转交给 Unity 自己做，两边才同口径
		Matrix4x4 t = Matrix4x4.identity;
		t.m03 = hx * 2f / screenWidth;
		t.m13 = hy * 2f / screenHeight;
		state.jitteredProjection = t * camera.projectionMatrix;//此刻 camera.projectionMatrix 还是原始值（渲染器是"先取再覆盖"）
	}

	//radix 进制下的第 index 个 Halton 数 ∈ [0,1)
	static float Halton (int index, int radix)
	{
		float result = 0f, f = 1f;
		while (index > 0)
		{
			f /= radix;
			result += f * (index % radix);
			index /= radix;
		}
		return result;
	}

	//把本帧要用的东西上传成全局 uniform（每帧一次，Setup 里调）
	void SetParameters (CommandBuffer buffer, CameraState state, TemporalAntiAliasingSettings settings)
	{
		//上一帧的历史图（shader 里用**线性**采样器采它；写的那张这一趟不能采）
		buffer.SetGlobalTexture(historyTexId, state.historyTextures[state.readIndex]);
		//历史图的纹素尺寸（邻域 3x3 / 边界判断用）
		buffer.SetGlobalVector(taaTexelSizeId, new Vector4(1f / state.width, 1f / state.height, state.width, state.height));
		//本帧抖动（UV 单位）：shader 里先 `uv -= _TAAJitter` 去掉抖动，再 `uv -= motion` 找上一帧
		buffer.SetGlobalVector(jitterId, state.jitter);
		//1 = 这帧不混合历史（首帧 / 重建 / 尺寸或 HDR 变 / 瞬移）
		buffer.SetGlobalInt(resetHistoryId, state.resetHistory ? 1 : 0);
		//上一帧的 VP（仅重投影版：用它把当前深度反投影成历史 UV）
		buffer.SetGlobalMatrix(prevViewProjId, state.previousViewProjection);
		//参数
		buffer.SetGlobalFloat(blendFactorId, settings.blendFactor);
		buffer.SetGlobalFloat(motionBlendScaleId, settings.motionBlendScale);
		buffer.SetGlobalFloat(sharpenStrengthId, settings.sharpenStrength);
	}

	///本帧要不要**丢掉历史**（Setup 里、上传参数之前调）。触发点：
	///  ① 没有历史 / 刚重建：`AllocateTextures` 会用 `resetHistory` + `hasHistory` 覆盖
	///     （**尺寸或 HDR 变**也走这条：它会重建，并把 previousViewProjection 复位）；
	///  ② 换了相机：由"每个相机一份 state"天然覆盖（换相机就是换 state，新 state 初值就是"要重置"）；**同一台相机**不用管；
	///  ③ 相机瞬移 / 急转；
	///  ④ 外部显式要求（`RequestResetHistory`）。
	bool NeedResetHistory (CameraState state, Matrix4x4 viewProjection)
	{
		//① 这台的图刚建出来、或者还没跑过一趟 ⇒ 历史里是黑的/垃圾
		if (!state.hasHistory)
		{
			return true;
		}

		//③ 瞬移/急转：把"上一帧视野里的一个参考点"用**本帧**的 VP 再投一次，跑出屏幕或在相机后面 ⇒ 历史已经对不上。
		//   为什么用"点"而不去逐个比较矩阵元素：平移和旋转都会让这个点跑 ⇒ 一个判据覆盖两种"瞬移"。
		//   为什么必须做：不做的话，那一下的重投影会把老画面从屏幕外拖进来 ⇒ 满屏拖影。
		//   参考点取"上一帧 VP 的逆作用在 clip 中心(z=0)"= 上一帧视野轴上的中景点，任何投影类型都好算。
		Vector3 refWS = state.previousViewProjection.inverse.MultiplyPoint(new Vector3(0f, 0f, 0f));
		Vector4 refCS = viewProjection * new Vector4(refWS.x, refWS.y, refWS.z, 1f);
		if (refCS.w <= 1e-6f)//透视下 clip.w = −视空间z ⇒ w ≤ 0 = 这个点跑到相机背后了
		{
			return true;
		}
		float invW = 1f / refCS.w;
		//投到 NDC 之外（|x| 或 |y| > 1）就算跑了。阈值故意宽松（要"跑出屏幕"才算）⇒ 普通移动不会误触发。
		return Mathf.Abs(refCS.x * invW) > 1f || Mathf.Abs(refCS.y * invW) > 1f;
	}
}
