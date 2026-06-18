using UnityEngine;
using UnityEngine.Rendering;    

//阴影与光照逻辑类似，先做成简化版的Lighting
public class Shadows
{
	const int maxShadowedDirectionalLightCount = 4; //带阴影的平行光数量，不能多，会降帧率
	const int maxCascades = 4;

	int ShadowedDirectionalLightCount; //记下已经预留了的光源数量，它从0开始增加

	static int dirShadowAtlasId = Shader.PropertyToID("_DirectionalShadowAtlas"), //级联阴影atlas的name id
		dirShadowMatricesId = Shader.PropertyToID("_DirectionalShadowMatrices"),//每个光源的矩阵
		cascadeCountId = Shader.PropertyToID("_CascadeCount"),
		cascadeCullingSpheresId = Shader.PropertyToID("_CascadeCullingSpheres"),
		//shadowDistanceId = Shader.PropertyToID("_ShadowDistance");//最后一个级联球体的剔除范围和配置的最大距离并不完全一致，因此传值来剔除
		cascadeDataId = Shader.PropertyToID("_CascadeData"),//要解决shadow acne，要考虑世界空间纹素大小一致，so传递级联数据
		shadowAtlasSizeId = Shader.PropertyToID("_ShadowAtlasSize"),//较大的滤波器需要更多的纹理采样，因此我们需要知道图集的大小和纹素大小
		shadowDistanceFadeId = Shader.PropertyToID("_ShadowDistanceFade");//同时包括最大距离和fade衰减
		
	static Matrix4x4[] dirShadowMatrices = new Matrix4x4[maxShadowedDirectionalLightCount * maxCascades];//现在看atlas大概会被分成16份
	
	static Vector4[] cascadeCullingSpheres = new Vector4[maxCascades],
		cascadeData = new Vector4[maxCascades];//它要存什么？
	
	const string bufferName = "Shadows";

	private CommandBuffer buffer = new CommandBuffer
	{
		name = bufferName
	};

	ScriptableRenderContext context;

	CullingResults cullingResults;

	ShadowSettings settings;

	public void Setup(ScriptableRenderContext context, CullingResults cullingResults,
		ShadowSettings settings)
	{
		this.context = context;
		this.cullingResults = cullingResults;
		this.settings = settings;

		ShadowedDirectionalLightCount = 0;

		useShadowMask = false;
	}

	void ExecuteBuffer()
	{
		context.ExecuteCommandBuffer(buffer);
		buffer.Clear();
	}
	
	//需要渲染阴影的一个定向光的配置
	struct ShadowedDirectionalLight
	{
		public int visibleLightIndex;
		public float slopeScaleBias;
		public float nearPlaneOffset;
		//所以是什么原因，作者选择不把normalBias也放进来？
	};

	//待渲染阴影的光源清单
	//ReserveDirectionalShadows 往里填，RenderDirectionalShadows(int index, int split, int tileSize)往外取
	ShadowedDirectionalLight[] ShadowedDirectionalLights = new ShadowedDirectionalLight[maxShadowedDirectionalLightCount];

	///判断光源是否生成阴影，任务是，为光源的shadowmap在阴影图集中预留空间，并存储相关信息
	///检查定向光shadowmap是否到最大数量，若还有空间，存储index，count++
	public Vector4 ReserveDirectionalShadows(Light light, int visibleLightIndex)
	{
		if (ShadowedDirectionalLightCount < maxShadowedDirectionalLightCount && //count未满
		    light.shadows != LightShadows.None && light.shadowStrength > 0)// && //光有阴影，阴影有强度
		    //cullingResults.GetShadowCasterBounds(visibleLightIndex, out Bounds b)) //说明这个index的定向光有需要渲染阴影的物体（false是没有，可能因为物体超出距离/物体不投影/没有物体被该光源影响），这函数也适用于其他类型光源
		{
			float maskChannel = -1;
			//针对shadowMask写的		有个小问题就是，现在这个值会根据相机与物体的距离是否大于settings.maxDistance而变化。这是因为cullingResults.GetShadowCasterBounds，而cullingResults是从CameraRenderer.Cull(maxDistance)到Lighting到Shadows一路传下来的
			//这好像反了吧，应该是没有cascade shadow的地方才用这个shadow mask吧？
			LightBakingOutput lightBaking = light.bakingOutput;
			if (lightBaking.lightmapBakeType == LightmapBakeType.Mixed &&//光源的“模式”
			    lightBaking.mixedLightingMode == MixedLightingMode.Shadowmask)//照明面板的混合照明->照明模式
			{
				useShadowMask = true;
				maskChannel = lightBaking.occlusionMaskChannel;//这是 Unity 烘焙时分配给每个灯的通道号（0/1/2/3）
			}

			if (!cullingResults.GetShadowCasterBounds(visibleLightIndex, out Bounds b))//把物体是否超出最大级联距离的判断后移到useShadowMask之后
			{
				//这是一个标记，GetShadowCasterBounds为false的时候，就是没渲染shadow map，那肯定要额外的标记，不能让shader去采样不存在的shadow map
				//让它为负数，GetDirectionalShadowAttenuation中，shadows.hlsl的directional.strength就是负的，directional.strength × global.strength会<=0，走采样baked shadow mask的路线
				return new Vector4(-light.shadowStrength, 0f, 0f, maskChannel);
			}
			
			ShadowedDirectionalLights[ShadowedDirectionalLightCount] =
				new ShadowedDirectionalLight
				{
					visibleLightIndex = visibleLightIndex ,
					slopeScaleBias = light.shadowBias,//Light component上边的属性，这个就是斜率bias
					nearPlaneOffset = light.shadowNearPlane
				};//如果某一个光要产生阴影，就记录它的index
			return new Vector4(light.shadowStrength, settings.directional.cascadeCount * ShadowedDirectionalLightCount++, light.shadowNormalBias, maskChannel);//阴影强度和阴影图块偏移//第二个参数，决定每个灯的起始tile，例如4灯*4级联，第一个灯级联在0~3，第二个灯级联在4~7，第三个灯级联在8~11...
		}
		return new Vector4(0f, 0f, 0f, -1f);//当光源不用shadow mask时，将索引设为 -1
	}

	///渲染阴影
	public void Render()
	{
		if (ShadowedDirectionalLightCount > 0)
		{
			RenderDirectionalShadows();
		}
		else
		{
			//一个直接的解决方案是只在有阴影时生成并释放纹理。然而，如果我们不申请纹理，那么对于WebGL 2.0会出问题，因为它把纹理和采样器绑定在一起。如果缺少纹理，它会用一个默认纹理替代，那会出错
			//WebGL 2.0的问题，可以用shader keyword来省略采样阴影的代码，但也挺复杂的，咱就生成一个1*1纹理来替代处理吧，正好让cleanup清理
			buffer.GetTemporaryRT(dirShadowAtlasId,1,1,32,FilterMode.Bilinear,RenderTextureFormat.Shadowmap);
		}
		
		buffer.BeginSample(bufferName);
		SetKeywords(shadowMaskKeywords, useShadowMask ? QualitySettings.shadowmaskMode == ShadowmaskMode.Shadowmask ? 0 : 1 : -1);
		buffer.EndSample(bufferName);
		ExecuteBuffer();
	}

	///渲染所有定向光阴影
	private void RenderDirectionalShadows()
	{
		int atlasSize = (int)settings.directional.atlasSize;
		buffer.GetTemporaryRT(dirShadowAtlasId, atlasSize, atlasSize, 32, FilterMode.Bilinear,RenderTextureFormat.Shadowmap);//深度格式32位，urp用的16位//GetTemporaryRT已经在隐式的SetGlobal了
		buffer.SetRenderTarget(dirShadowAtlasId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);//保存但不读取？
		buffer.ClearRenderTarget(true, false, Color.clear);//清深度不清颜色
		buffer.BeginSample(bufferName);//专门为shadows的一个sample块
		ExecuteBuffer();

		int tiles = ShadowedDirectionalLightCount * settings.directional.cascadeCount;
		int split = tiles <= 1 ? 1 : tiles <= 4 ? 2 : 4; //定向光数量和阴影级联数量乘积，决定把atlas分成多少份
		int tileSize = atlasSize / split;
		for (int i = 0; i < ShadowedDirectionalLightCount; i++)
		{
			RenderDirectionalShadows(i, split, tileSize);//由于我们目前仅支持单个带阴影的光源，因此其图块大小与图集大小相等?
		}

		buffer.SetGlobalInt(cascadeCountId, settings.directional.cascadeCount);
		buffer.SetGlobalVectorArray(cascadeCullingSpheresId, cascadeCullingSpheres);
		buffer.SetGlobalVectorArray(cascadeDataId, cascadeData);//?
		buffer.SetGlobalMatrixArray(dirShadowMatricesId, dirShadowMatrices);
		//buffer.SetGlobalFloat(shadowDistanceId, settings.maxDistance);
		float f = 1f - settings.directional.cascadeFade;//实现级联阴影最外层与外边的平滑过渡（类似最大距离的fade），这个用平方衰减
		buffer.SetGlobalVector(shadowDistanceFadeId, new Vector4(1f / settings.maxDistance, 1f / settings.distanceFade, 1f/(1f - f * f)));//用除法，这样shader里就能用乘法，快一点
		SetKeywords(directionalFilterKeywords, (int)settings.directional.filter - 1);
		SetKeywords(cascadeBlendKeywords, (int)settings.directional.cascadeBlend - 1);
		buffer.SetGlobalVector(shadowAtlasSizeId, new Vector4(atlasSize, 1f / atlasSize));
		buffer.EndSample(bufferName);
		ExecuteBuffer();
	}

	///现在有贴图atlas，和未知个数的分割，要确定某个tile在atlas上的xy偏移量
	Vector2 SetTileViewport(int index, int split, float tileSize)
	{
		Vector2 offset = new Vector2(index % split, index / split);//除法分数可能丢失，就是要让它丢失
		buffer.SetViewport(new Rect(offset.x * tileSize,offset.y * tileSize, tileSize,tileSize));//前两个偏移量，后两个宽高
		return offset;//也就是00，01，10，11这样的
	}
	
	//针对一个定向光，渲染定向光阴影
	void RenderDirectionalShadows(int index, int split, int tileSize)//index是阴影光源的索引，tileSize是在图集中的图块大小
	{
		ShadowedDirectionalLight light = ShadowedDirectionalLights[index];//用index获取产生阴影的light
		// var shadowSettings = new ShadowDrawingSettings(cullingResults, light.visibleLightIndex, BatchCullingProjectionType.Orthographic);//疑似2022版需要标明是正交投影而2023版又不用标了
		var shadowSettings = new ShadowDrawingSettings(cullingResults, light.visibleLightIndex);//Core库的类
		
		int cascadeCount = settings.directional.cascadeCount;
		int tileOffset = index * cascadeCount;//这个光源的 tile 起始位置//例如4灯*4级联，第一个灯级联在0~3，第二个灯级联在4~7...//每个灯有一个tileOffset
		Vector3 ratios = settings.directional.CascadeRatios;

		float cullingFactor = Mathf.Max(0f, 0.8f - settings.directional.cascadeFade);
		
		for (int i = 0; i < cascadeCount; i++)
		{
			//第i个级联的VP矩阵，覆盖不同的距离范围，在ComputeDirectionalShadowMatricesAndCullingPrimitives里面，就已经针对级联覆盖的比例在调整矩阵了，而不是同一个灯每个级联同一矩阵
			cullingResults.ComputeDirectionalShadowMatricesAndCullingPrimitives( //split的一些输入参数是用于级联阴影的//这个函数写了Directional，所以会自动设置为正交投影，类似的还有Spot和Point，那俩是透视投影的
				light.visibleLightIndex, i, cascadeCount, ratios, tileSize, light.nearPlaneOffset,
				out Matrix4x4 viewMatrix, out Matrix4x4 projectionMatrix,
				out ShadowSplitData splitData
			); //方向光被假设为无限远，因此它没有真正的位置。我们需要找到与光的方向匹配的view和projection matrix，用来构建一个裁剪空间立方体，与相机可见的区域重叠，能够容纳光的阴影
			splitData.shadowCascadeBlendCullingFactor = cullingFactor;//剔除不同级联间的，重复渲染的shadowmap
			shadowSettings.splitData = splitData; //ShadowSplitData包含有关如何剔除投射阴影物体的信息???
			if (index == 0)
			{
				// Vector4 cullingSphere = splitData.cullingSphere; //某个光源的级联裁剪球，在此只是取一次就ok，因为所有光源的级联是等效的。
				// cullingSphere.w *= cullingSphere.w;//因为是球体距离计算，这样能省去sqrt或者length，小优化吧
				// cascadeCullingSpheres[i] = cullingSphere;
				SetCascadeData(i, splitData.cullingSphere, tileSize);
			}
			int tileIndex = tileOffset + i;//同一个灯的每个级联的位置
			//SetTileViewport(index, split, tileSize);
			dirShadowMatrices[tileIndex] = ConvertToAtlasMatrix(projectionMatrix * viewMatrix, //从世界空间到光源投影空间的转换矩阵
				SetTileViewport(tileIndex, split, tileSize), split); //考虑tile的offset和atlas的split
			buffer.SetViewProjectionMatrices(viewMatrix, projectionMatrix);
			
			//为了解决shadow acne↓
			buffer.SetGlobalDepthBias(0f,light.slopeScaleBias);//第一个参数是恒定偏移量，需要非常大的数如5万~50万，但这会造成peter panning；第二个参数是斜率比例偏移，正对光源的表面不偏移，平行光源的表面偏移无穷大，然而Light面板里没有这个值，它默认是0
			ExecuteBuffer();
			context.DrawShadows(ref shadowSettings); //实际在绘制阴影的是这一步//DrawShadows 只会渲染具有 ShadowCaster 通道的材质的对象
			buffer.SetGlobalDepthBias(0f, 0f);
		}
	}

	//从“世界坐标->裁剪空间坐标”变成“世界坐标->shadowmap对应位置的纹理坐标”
	Matrix4x4 ConvertToAtlasMatrix(Matrix4x4 m, Vector2 offset, int split)
	{
		if (SystemInfo.usesReversedZBuffer)//系统若在用反向ZBuffer，把矩阵Z都取反//传统OpenGL，0近1远是正常的Z，Vulkan/DX，Z是1近0远是reversed Z
		{
			m.m20 = -m.m20;
			m.m21 = -m.m21;
			m.m22 = -m.m22;
			m.m23 = -m.m23;
		}

		//剪裁空间是-1到1的立方体。但是纹理坐标和深度范围0到1。通过将XYZ维度进行缩放和偏移，让shader里矩阵变换后能直接采样贴图。实际上就是对所有xyz*0.5+0.5
		//		虽然可以通过矩阵乘法来实现这一点，但这将导致大量的零乘法和不必要的加法运算。因此，直接调整矩阵
		//然后再加上应用图块的偏移和缩放
		//下边的操作等同于：左乘应用*0.5+0.5的矩阵，再左乘tile偏移缩放的矩阵
		float scale = 1f / split;
		m.m00 = (0.5f * (m.m00 + m.m30) + offset.x * m.m30) * scale;//(0.5f * (m.m00 + m.m30)就是原值 * 0.5 + 0.5 的矩阵乘法展开形式，只是简化的计算结果而已
		m.m01 = (0.5f * (m.m01 + m.m31) + offset.x * m.m31) * scale;//(.... + offset * m3n)*scale，就是让采样的时候，xy*scale缩放，再加上offset*scale偏移
		m.m02 = (0.5f * (m.m02 + m.m32) + offset.x * m.m32) * scale;
		m.m03 = (0.5f * (m.m03 + m.m33) + offset.x * m.m33) * scale;
		m.m10 = (0.5f * (m.m10 + m.m30) + offset.y * m.m30) * scale;
		m.m11 = (0.5f * (m.m11 + m.m31) + offset.y * m.m31) * scale;
		m.m12 = (0.5f * (m.m12 + m.m32) + offset.y * m.m32) * scale;
		m.m13 = (0.5f * (m.m13 + m.m33) + offset.y * m.m33) * scale;
		//Z只需要*0.5+0.5，让深度映射到 [0,1]，否则 SAMPLE_TEXTURE2D_SHADOW 深度比较会出错
		m.m20 = 0.5f * (m.m20 + m.m30);
		m.m21 = 0.5f * (m.m21 + m.m31);
		m.m22 = 0.5f * (m.m22 + m.m32);
		m.m23 = 0.5f * (m.m23 + m.m33);
		return m;
	}

	public void Cleanup()
	{
		buffer.ReleaseTemporaryRT(dirShadowAtlasId);
		ExecuteBuffer();
	}

	//同时在处理某一个级联的cascadeData和cascadeCullingSpheres（每个灯相同）
	void SetCascadeData(int index, Vector4 cullingSphere, float tileSize)
	{
		float texelSize = 2f * cullingSphere.w / tileSize;//级联裁剪球的半径*2，就是它的外接正方形的边长，再除以tile大小，就是shadow map每个像素对应的世界空间长度
		float filterSize = texelSize * ((float)settings.directional.filter + 1f);//增大pcf半径让阴影更平滑，但会导致shadow acne再次出现，所以要增大法线偏差，匹配滤波器的大小
		cullingSphere.w -= filterSize;//pcf增大，增加采样区域，意味着采样点可能在级联剔除球外，那么先减一下，到pcf往外采样的时候就不会超出球外了
		cullingSphere.w *= cullingSphere.w;
		cascadeCullingSpheres[index] = cullingSphere;
		cascadeData[index] = new Vector4(
			1f / cullingSphere.w, //省除法，存1/半径²，因为shader里distanceSqr是距离平方
			filterSize * 1.4142136f);//采样阴影的时候，尝试把表面沿法线向外偏移一定长度，这样能避免自阴影，这个长度就是texelSize，考虑正方形纹素，偏移最多乘根号二
	}

	//控制滤波模式的shader keyword
	private static string[] directionalFilterKeywords =
	{
		"_DIRECTIONAL_PCF3",
		"_DIRECTIONAL_PCF5",
		"_DIRECTIONAL_PCF7",
	};

	void SetKeywords(string[] keywords, int enabledIndex)
	{
		//int enabledIndex = (int)settings.directional.filter - 1;//因为对应的PCF3x3是1，PCF5x5是2，PCF7x7是3，所以-1就是012
		for (int i = 0; i < keywords.Length; i++)//在012循环
		{
			if (i == enabledIndex)
			{
				buffer.EnableShaderKeyword(keywords[i]);
			}
			else
			{
				buffer.DisableShaderKeyword(keywords[i]);
			}
		}
	}

	static string[] cascadeBlendKeywords =
	{
		"_CASCADE_BLEND_SOFT",
		"_CASCADE_BLEND_DITHER"
	};
	
	
	
	//以下为shadowMask的内容
	private static string[] shadowMaskKeywords = //项目设置->质量，shadowmask的两种类型
	{
		"_SHADOW_MASK_ALWAYS",//shadowmask模式				不会为静态物体渲染实时阴影，静态物体只用烘焙阴影		是unity内部代码，用这个模式就不执行静态物体的"Shadow Caster Pass"，省的消耗就是这个，仍会采样shadow map，但采样的时候对应位置没内容，和baked阴影取min，就是采用baked阴影
		"_SHADOW_MASK_DISTANCE"//distance shadowmask模式	静态物体用实时和烘焙的混合
	};

	//是否使用阴影遮罩	每帧重新评估该字段
	private bool useShadowMask;
}
