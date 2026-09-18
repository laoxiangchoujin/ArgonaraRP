using UnityEngine;
using UnityEngine.Rendering;

public class ScreenSpaceReflection
{
    //=========================== SSR 的参数上传 ===========================
	//SSR 的追踪/降噪调参都是裸的全局 uniform（见 ScreenSpaceReflection.hlsl），前后向各画一趟 trace，
	//参数必须完全一致 ⇒ 上传放这里，两个渲染器都调它（名字一一对应，改一个地方就够）。
	static int
		ssrTotalRayLengthId = Shader.PropertyToID("_SSRTotalRayLength"),
		ssrPixelStrideId = Shader.PropertyToID("_SSRPixelStride"),
		ssrStepCountLimitId = Shader.PropertyToID("_SSRStepCountLimit"),
		ssrNearStepBoldenRangeId = Shader.PropertyToID("_SSRNearStepBoldenRange"),
		ssrPixelThicknessId = Shader.PropertyToID("_SSRPixelThickness"),
		ssrBackRayFadeWidthId = Shader.PropertyToID("_SSRBackRayFadeWidth"),
		ssrScreenEdgeFadeStartId = Shader.PropertyToID("_SSRScreenEdgeFadeStart"),
		ssrMarchFadeStrengthId = Shader.PropertyToID("_SSRMarchFadeStrength"),
		ssrIntensityId = Shader.PropertyToID("_SSRIntensity"),
		ssrRoughnessMipScaleId = Shader.PropertyToID("_SSRRoughnessMipScale"),
		ssrRoughnessMipBiasId = Shader.PropertyToID("_SSRRoughnessMipBias"),
		ssrFireflySuppressionId = Shader.PropertyToID("_SSRFireflySuppression"),
		ssrFireflyStrengthId = Shader.PropertyToID("_SSRFireflyStrength");

	///把 SSRSettings 里的调参上传成全局 uniform（每帧一次就够，不必每趟都传）
	private static void SetParameters(CommandBuffer buffer, SSRSettings ssrSettings)
	{
		//追踪
		buffer.SetGlobalFloat(ssrTotalRayLengthId, ssrSettings.totalRayLength);
		buffer.SetGlobalFloat(ssrPixelStrideId, ssrSettings.pixelStride);
		buffer.SetGlobalInt(ssrStepCountLimitId, ssrSettings.stepCountLimit);
		buffer.SetGlobalFloat(ssrNearStepBoldenRangeId, ssrSettings.nearStepBoldenRange);
		buffer.SetGlobalFloat(ssrPixelThicknessId, ssrSettings.pixelThickness);
		//命中后的淡出
		buffer.SetGlobalFloat(ssrBackRayFadeWidthId, ssrSettings.backRayFadeWidth);
		buffer.SetGlobalFloat(ssrScreenEdgeFadeStartId, ssrSettings.screenEdgeFadeStart);
		buffer.SetGlobalFloat(ssrMarchFadeStrengthId, ssrSettings.marchFadeStrength);
		//合成/质量
		buffer.SetGlobalFloat(ssrIntensityId, ssrSettings.intensity);
		buffer.SetGlobalFloat(ssrRoughnessMipScaleId, ssrSettings.roughnessMipScale);
		buffer.SetGlobalFloat(ssrRoughnessMipBiasId, ssrSettings.roughnessMipBias);
		buffer.SetGlobalFloat(ssrFireflySuppressionId, ssrSettings.fireflySuppression ? 1f : 0f);
		buffer.SetGlobalFloat(ssrFireflyStrengthId, ssrSettings.fireflyStrength);
	}

	//=========================== SSR 的两张持久反射图（跨帧双缓冲）==========================
	//前向和延迟都是"本帧追、下一帧用"：反射源得是"不透明+天空盒"的本帧快照，而本帧的物体在拷快照之前就画完了。
	//所以这两张图必须**跨帧持久**，而且**双缓冲**：本帧读 ssrReadIndex 那张（上一帧的结果）、写另一张，帧末交换。
	//（不能用 GetTemporaryRT —— 它每帧都会被回收）
	//这几个 id 只在本类里用（同一套名字，shader 才能复用同一批 pass）
	private static int
		ssrTexId = Shader.PropertyToID("_SSRTex"),
		ssrTexTempBlurId = Shader.PropertyToID("_SSRTex_TempBlur"),
		ssrTexelSizeId = Shader.PropertyToID("_SSRTexelSize");

	private RenderTexture[] ssrTextures = new RenderTexture[2];//两张持久的反射图（轮换使用）
	private int ssrReadIndex;//本帧"读"的那张（= 上一帧追出来的结果）；另一张（1-ssrReadIndex）是本帧要写的
	//上一次是按什么尺寸/HDR开关建的图（⚠️ 不能拿 rt.format 去比，见下面注释）
	int ssrTextureWidth, ssrTextureHeight;
	bool ssrTextureHDR;

	///按屏幕尺寸/HDR开关建（或重建）两张跨帧的反射图（双缓冲）+ 本帧的 blur 倒手图。
	///（"关掉 SSR"那条路不走这里：Setup 里走 ReleaseTextures + 绑黑图）
	///⚠️ 会把新建的图顺手清一次（新图内容未定义，不清的话第一帧/重建帧会把垃圾当"上一帧的结果"），
	///   清完渲染目标停在最后清的那张图上 ⇒ 调用方紧接着要画东西的话，自己 SetRenderTarget 恢复。
	private void AllocateTextures (CommandBuffer buffer, int screenWidth, int screenHeight, bool hdr, bool fullResolution)
	{
		//分辨率由设置里的开关决定：默认半分辨率（SSR 本身就是个低频结果，像素数省 4 倍）；
		//开全分辨率 = 反射内容的分辨率上限翻倍（高频边缘的台阶细一半），代价是显存/带宽 ×4、trace 像素数 ×4。
		int width = Mathf.Max(1, fullResolution ? screenWidth : screenWidth / 2);
		int height = Mathf.Max(1, fullResolution ? screenHeight : screenHeight / 2);
		//必须是 HDR（不能用阴影那种 R8）：它存的是**颜色**，反射亮度会超过 1
		RenderTextureFormat format = hdr ? RenderTextureFormat.DefaultHDR : RenderTextureFormat.Default;

		//⚠️ 判断"参数变了没"**不能**拿 rt.format 去比：请求 Default / DefaultHDR 时，RenderTexture.format
		//   可能返回平台**解析后的具体格式**（和请求值不相等）⇒ 每帧都判定"变了" ⇒ 每帧销毁重建 ⇒
		//   两张图永远是空的（采到全 0，而 trace 那几趟当帧写、看着正常）。所以自己记住上次按什么建的。
		bool needRebuild = ssrTextures[0] == null ||
		                   ssrTextureWidth != width || ssrTextureHeight != height || ssrTextureHDR != hdr;
		if (needRebuild)
		{
			ReleaseTextures();//两张一起换，保证双缓冲从同一起点开始
			ssrTextureWidth = width;
			ssrTextureHeight = height;
			ssrTextureHDR = hdr;
			for (int i = 0; i < ssrTextures.Length; i++)
			{
				ssrTextures[i] = new RenderTexture(width, height, 0, format, RenderTextureReadWrite.Linear)
				{
					name = "_SSRTex" + i,
					hideFlags = HideFlags.HideAndDontSave,
					//Bilinear 而不是 Point：blur 要按纹素取邻居、接收面采样它时还要双线性放大
					filterMode = FilterMode.Bilinear,
					wrapMode = TextureWrapMode.Clamp,
					useMipMap = false,
					autoGenerateMips = false,
				};
				ssrTextures[i].Create();
				//新建的图内容未定义：清一次，免得第一帧（或重建后的那一帧）把垃圾当成"上一帧的结果"
				buffer.SetRenderTarget(ssrTextures[i], RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
				buffer.ClearRenderTarget(false, true, Color.clear);
			}
		}
		//blur 取邻居要按这两张图自己的纹素尺寸（不能沿用 _CameraBufferSize）
		buffer.SetGlobalVector(ssrTexelSizeId, new Vector4(1f / width, 1f / height, width, height));

		//倒手图：同一张纹理不能在同一趟绘制里既读又写，横/竖两趟之间来回倒一次（半分辨率、每帧临时；
		//由下面的 Draw 在竖blur用完时释放）
		buffer.GetTemporaryRT(ssrTexTempBlurId, width, height, 0, FilterMode.Bilinear, format);
	}

	///释放两张持久的反射图（开关关掉的那一帧、以及 Dispose 时）。blur 倒手图是临时图，由 Draw 自己释放
	private void ReleaseTextures()
	{
		for (int i = 0; i < ssrTextures.Length; i++)
		{
			if (ssrTextures[i] != null)
			{
				ssrTextures[i].Release();
				CoreUtils.Destroy(ssrTextures[i]);
				ssrTextures[i] = null;
			}
		}
	}

	//=========================== SSR 的每帧流程（前向/延迟共用）==========================
	//两条路的 SSR 只有三处不同：法线来源（延迟读GBuffer2 / 前向读depth-normal prepass）、
	//颜色快照次数（延迟两次 / 前向一次）、以及"颜色与深度附件的 id"。
	//这里放的是完全相同的那部分：**建图/绑图/传参**（useSSR 真）、**画那三趟**、以及**释放**；
	//附件 id 由调用方传进来。
	//**判定不在这里**：用下面的 ShouldRender（公共部分）+ 各自附加条件，由渲染器自己算好、当参数传进来。
	Material ssrMaterial;//本帧要画的材质（Setup 时从 SSRSettings 拿；Draw 用它画那三趟，Dispose 负责销毁）
	//（"本帧走不走SSR"由**渲染器自己算**（各自再添附加条件）后当参数传进来 ⇒ 这里不存这个状态）

	//ScreenSpaceReflection.shader 里的 pass 顺序（**必须和 shader 里 Pass 的先后完全一致**）
	private enum Pass
	{
		Trace,          //0：追踪
		BlurHorizontal, //1：横blur
		BlurVertical,   //2：竖blur
		//（原来还有个 3 = 间接高光合成，已删：两条路都在**物体pass**里把"环境反射 + 上一帧SSR"混好了）
	}

	///本帧走不走 SSR 的**公共判定**（渲染器自己再添附加条件，例如前向要"得有颜色快照"）。
	///总开关 + 配了shader才走（material 由 SSRSettings 惰性创建，两个渲染器共用一个）
	///  + 反射相机（探针）不跑：cubemap 投影下"反射方向"本来就没意义，而且探针每帧要渲染6次，白跑三趟
	public static bool ShouldRender (SSRSettings settings, Camera camera)
	{
		return settings != null && settings.enabled && settings.Material != null
		       && camera.cameraType != CameraType.Reflection;
	}

	///**每帧都调**（两条路都在这里决定"本帧走不走 SSR"）：
	///  use 真 ⇒ 建/重建两张持久反射图 → 把 _SSRTex 绑成"上一帧那张" → 上传调参；
	///  use 假 ⇒ 释放两张持久图 + 把 _SSRTex 绑成 **1×1 纯黑**（a = 0 ⇒ 物体着色时逐像素退回环境反射）。
	///⚠️ 两路都必须执行（别只在调用点写 if）：上一帧可能还开着，不释放/不绑黑图的话，
	///   本帧的物体会采到上一帧那张已经不该再用的图。
	///**要放在"设置自己的渲染目标"之前**（重建那几帧里会清图、把渲染目标设成 SSR 图）。
	public void Setup (CommandBuffer buffer, SSRSettings settings, bool use,
		int screenWidth, int screenHeight, bool hdr)
	{
		if (!use || settings == null || settings.Material == null)
		{
			//关掉 SSR：释放两张持久图 + 绑黑图（不能沿用上一帧的图，否则反射会一直"留在画面上"）
			ReleaseTextures();
			buffer.SetGlobalTexture(ssrTexId, Texture2D.blackTexture);
			return;
		}

		ssrMaterial = settings.Material;//存下来：Draw 用它画那三趟，Dispose 负责销毁

		//两张跨帧的双缓冲图 + 本帧的 blur 倒手图（分辨率由设置里的 fullResolution 决定）
		AllocateTextures(buffer, screenWidth, screenHeight, hdr, settings.fullResolution);

		//把 _SSRTex 绑成"读"的那张（= **上一帧**追出来的结果，本帧的物体着色时会采它）
		buffer.SetGlobalTexture(ssrTexId, ssrTextures[ssrReadIndex]);
		SetParameters(buffer, settings);
	}

	///三趟（追踪 + 横竖两趟blur）：写到"本帧要写的那张"反射图上，再把 _SSRTex 绑成当帧这张（给后面画的透明物用），
	///最后交换双缓冲索引 ⇒ 下一帧才消费它。本帧的 blur 倒手图也在这里释放（只被中间那两趟用）。
	///colorAttachment / depthAttachment：调用方自己的两个附件 id（两侧名字不同，所以传进来）。
	///⚠️ 这里会把 buffer.name 改成 "Screen Space SSR"（帧调试器分组）⇒ 调用方画完自己恢复；
	///   也因为结尾没有 ExecuteBuffer，**调用方要紧跟一句 ExecuteBuffer()**（让 RT/全局绑定对透明物立刻生效）。
	public void Draw (CommandBuffer buffer, RenderTargetIdentifier colorAttachment,
		RenderTargetIdentifier depthAttachment)
	{
		if (ssrMaterial == null)//Setup 里已经挡过一道，这里再兜一层，免得空引用
		{
			return;
		}

		//本帧写这张；另一张（ssrReadIndex 那张）是"上一帧的结果"，Setup 里已经绑给 _SSRTex 了
		RenderTexture writeTexture = ssrTextures[1 - ssrReadIndex];

		//帧调试器是按"命令缓冲区的名字"给每次执行分组的：不改名字的话，这几趟会挂在上一段下面
		buffer.name = "Screen Space Reflection";
		buffer.BeginSample("Screen Space Reflection");

		//1.追踪：屏幕空间步进找交点 → 本帧的反射图（rgb=反射色、a=可信度）
		//（trace 自己不采 _SSRTex，但后面两趟 blur 要采它 ⇒ 顺手先把它绑成本帧这张。
		//  顺带：这句也决定了 Draw 之后画的**透明物**采到的是本帧刚追出来的这张，
		//  而不透明物体在前面已经用过早一帧那张（Setup 里绑的））
		buffer.SetRenderTarget(writeTexture, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
		buffer.SetGlobalTexture(ssrTexId, writeTexture);
		buffer.DrawProcedural(Matrix4x4.identity, ssrMaterial, (int)Pass.Trace, MeshTopology.Triangles, 3);

		//2.横向blur：_SSRTex(本帧这张) → _SSRTex_TempBlur
		buffer.SetRenderTarget(ssrTexTempBlurId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
		buffer.DrawProcedural(Matrix4x4.identity, ssrMaterial, (int)Pass.BlurHorizontal, MeshTopology.Triangles, 3);
		buffer.SetGlobalTexture(ssrTexTempBlurId, ssrTexTempBlurId);//给下一趟采样用

		//3.纵向blur：_SSRTex_TempBlur → 本帧的反射图（转一圈回来；两趟的形状见 shader 里的注释）
		buffer.SetRenderTarget(writeTexture, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
		buffer.DrawProcedural(Matrix4x4.identity, ssrMaterial, (int)Pass.BlurVertical, MeshTopology.Triangles, 3);
		//倒手图用完就还（本帧只有上面两趟 blur 采它）
		buffer.ReleaseTemporaryRT(ssrTexTempBlurId);

		//4.恢复主渲染目标：紧接着要画透明物了（这既是它们要的 RT + 深度，也顺手解决
		//"最后一趟blur把渲染目标设成了反射图"的问题）。Load 保住已经画好的颜色和深度
		buffer.SetRenderTarget(colorAttachment, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
			depthAttachment, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);

		buffer.EndSample("Screen Space Reflection");

		//5.帧末交换：下一帧的"上一帧结果"= 本帧刚追出来的这张
		//⚠️ 交换只能在这做（AllocateTextures 里不能重置 ssrReadIndex，否则双缓冲永远不交换）
		ssrReadIndex = 1 - ssrReadIndex;
	}

	///释放这个类持有的东西（渲染器 Dispose 时调）：两张跨帧的持久反射图 + 那份材质。
	///（本帧的 blur 倒手图是临时图，由 Draw 自己还；关掉 SSR 那一帧的释放走 ReleaseTextures）
	public void Dispose ()
	{
		ReleaseTextures();
		CoreUtils.Destroy(ssrMaterial);
		ssrMaterial = null;
	}
}
