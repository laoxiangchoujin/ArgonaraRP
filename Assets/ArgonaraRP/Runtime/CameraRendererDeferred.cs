using UnityEngine;
using UnityEngine.Rendering;

///RenderPipeline需要按顺序处理每个相机，把这个责任转交给此类
///它大致相当于URP的scriptable renderer
//这种方法，让每个相机在未来更容易支持不同的渲染方法，如一个渲染第一人称视图，一个渲染三维地图，或前向和延迟渲染
public partial class CameraRendererDeferred : CameraRendererBase
{
    ScriptableRenderContext context;
    Camera camera;

    private const string bufferName = "Render Camera Deferred";
    private CommandBuffer buffer = new CommandBuffer
    {
        name = bufferName
    };

    Lighting lighting = new Lighting();
    
    PostFXStack postFXStack = new PostFXStack();//堆栈实例

    private bool useHDR;
    
    bool useScaleRendering;
    public const float renderScaleMin = 0.1f, renderScaleMax = 2f;
    private Vector2Int bufferSize;

    static CameraSettings defaultCameraSettings = new CameraSettings();//没有挂组件的相机用默认设置

    bool useColorTexture, 
        useIntermediateBuffer;//这个使用中间缓冲，在延迟中我们定为，始终是1，也就是永远先画到colorTexture上，然后再copy到屏幕上
    
    
    
    ///绘制相机能看到的所有几何图形
    public override void Render(ScriptableRenderContext context, Camera camera, CameraBufferSettings bufferSettings,
        bool useDynamicBatching, bool useGPUInsancing, bool useLightsPerObject, 
        ShadowSettings shadowSettings, PostFXSettings postFXSettings, int colorLUTResolution)
    {
        this.context = context;
        this.camera = camera;
        
        //------------------------------1.前期准备---------------------------------

        //实时反射探针(realtime reflection probe)每帧6次渲染，若也开启copy颜色和深度，开销大，这里单独开关
        if (camera.cameraType == CameraType.Reflection)
        {
            return;
        }
        
        //尝试在场景里真实存在的Camera相机上，找到本管线自定义的，设置相机final pass混合模式和逐相机重载设置CameraSettings的组件
        var argonaraRPCamera = camera.GetComponent<ArgonaraRenderPipelineCamera>();
        CameraSettings cameraSettings = argonaraRPCamera ? argonaraRPCamera.Settings : defaultCameraSettings;//没找到就默认One,Zero，，，覆写的要用One,OneMinusSrcAlpha

        //实际的相机camera和SceneView由管线+相机双重开关控制
        useColorTexture = bufferSettings.copyColor && cameraSettings.copyColor;
        
        //相机自己的后处理设置覆盖管线全局设置
        if (cameraSettings.overridePostFX)
        {
            postFXSettings = cameraSettings.postFXSettings;
        }

        //渲染缩放，由相机和全局共同控制
        float renderScale = cameraSettings.GetRenderScale(bufferSettings.renderScale);
        useScaleRendering = renderScale < 0.99f || renderScale > 1.01f;
        
        PrepareBuffer();//帧调试器里能看到相机名称
        PrepareForSceneWindow();//给scene view里的UI物体添加到世界几何体中，因为可能会为场景增加一些几何体，所以要在剔除前做
        if (!Cull(shadowSettings.maxDistance))
        {
            return;
        }
        
        useHDR = bufferSettings.allowHDR && camera.allowHDR;//HDR双控：管线全局开关 + 相机自身开关

        if (useScaleRendering)
        {
            renderScale = Mathf.Clamp(renderScale, renderScaleMin, renderScaleMax);
            bufferSize.x = (int) (camera.pixelWidth * renderScale);
            bufferSize.y = (int) (camera.pixelHeight * renderScale);
        }
        else
        {
            bufferSize.x = camera.pixelWidth;
            bufferSize.y = camera.pixelHeight;
        }

        //lighting的Setup包含了shadows的render指令，先渲染阴影
        buffer.BeginSample(SampleName);
        buffer.SetGlobalVector(bufferSizeId, new Vector4(1f/bufferSize.x, 1f/bufferSize.y, bufferSize.x, bufferSize.y));//渲染缩放后，替代_ScreenParams
        ExecuteBuffer();
        lighting.Setup(context, cullingResults, shadowSettings, useLightsPerObject,
            cameraSettings.maskLights ? cameraSettings.renderingLayerMask : -1);//相机可选的灯光渲染层过滤
        postFXStack.Setup(context, camera, bufferSize, postFXSettings, useHDR, colorLUTResolution, cameraSettings.finalBlendMode, bufferSettings.bicubicRescaling);
        buffer.EndSample(SampleName);

        //------------------------------2.相机主进程：准备和绘制---------------------------------
        //2.1准备渲染
        Setup();
        //2.2渲染
        DrawVisibleGeometry(useDynamicBatching, useGPUInsancing, useLightsPerObject, cameraSettings.renderingLayerMask);
        
        DrawUnsupportedShaders();
        
        // buffer.EndSample("Setup");
        // ExecuteBuffer();

        //------------------------------3.Gizmos、后处理，到屏幕上---------------------------------
        DrawGizmosBeforeFX();//gizmos要区分在后处理前后有不一样
        if (postFXStack.IsActive)
        {
            postFXStack.Render(colorAttachmentId);//后处理确实在后边啊
        }
        else if (useIntermediateBuffer)
        {
            DrawFinal(cameraSettings.finalBlendMode);//无后处理时，复制颜色附件到CameraTarget，尊重视口和混合模式
            ExecuteBuffer();
        }
        DrawGizmosAfterFX();//这部分gizmos，在后处理后，此时它始终不被物体遮挡，好像是因为没有场景深度了，没法做深度测试
        
        Cleanup();
        Submit(); //第二个endSample
    }

    CullingResults cullingResults;
    
    ///CPU的视锥剔除
    bool Cull(float maxShadowDistance)
    {
        if (camera.TryGetCullingParameters(out ScriptableCullingParameters p))
        {
            p.shadowDistance = Mathf.Min(maxShadowDistance, camera.farClipPlane);//剔除会需要用到阴影距离，主相机周围多少米范围内的物体才需要考虑投射阴影，当然不需要比远平面还远
            cullingResults = context.Cull(ref p);
            return true;
        }
        return false;
    }

    
    
    
    
    //这里attachment附件，就是用于写入颜色，然后经过copy，另一张图再用于读取
    static int colorAttachmentId = Shader.PropertyToID("_CameraColorAttachment");
    //static int depthAttachmentId = Shader.PropertyToID("_CameraDepthAttachment");
    static int colorTextureId = Shader.PropertyToID("_CameraColorTexture");
    static int depthTextureId = Shader.PropertyToID("_CameraDepthTexture");//这里GBufferDepth当作这张纹理的attachment，用于写入，而它用于读取
    static int sourceTextureId = Shader.PropertyToID("_SourceTexture");
    static int srcBlendId = Shader.PropertyToID("_CameraSrcBlend");
    static int dstBlendId = Shader.PropertyToID("_CameraDstBlend");

    private static int bufferSizeId = Shader.PropertyToID("_CameraBufferSize");//因为unity默认提供的_ScreenParams数值不会随我们的渲染缩放调整，需要自己传值替代
    
    static int gDepthId = Shader.PropertyToID("_GBufferDepth");
    static int[] gBuffersId =
    {
        Shader.PropertyToID("_GBuffer1"), Shader.PropertyToID("_GBuffer2") ,
        Shader.PropertyToID("_GBuffer3"), Shader.PropertyToID("_GBuffer4"),
        Shader.PropertyToID("_GBuffer5")
    };
    //这里，暂时用它存一下indrect diffuse，毕竟光照计算要用到。我想的是把间接diffuse暂存，间接高光在光照计算算
    //等实现什么实时光照的方法后，弃用这个纹理
    
    ///将相机的属性应用于上下文context
    void Setup()
    {
        context.SetupCameraProperties(camera); //渲染前设置正确的相机矩阵unity_MatrixVP
        //手动设置 unity_MatrixInvVP（SetupCameraProperties 可能不设它）   GBuffer光照计算需要它来重建世界坐标
        Matrix4x4 view = camera.worldToCameraMatrix;
        Matrix4x4 proj = GL.GetGPUProjectionMatrix(camera.projectionMatrix, true);
        buffer.SetGlobalMatrix(Shader.PropertyToID("unity_MatrixInvVP"), (proj * view).inverse);
        
        CameraClearFlags flags = camera.clearFlags;//它有4个值，1~4是Skybox,Color,Depth,Nothing，

        CreateGBuffers();

        useIntermediateBuffer = useScaleRendering || 
                                useColorTexture || 
                                postFXStack.IsActive;
        if (useIntermediateBuffer)//需要获取帧缓冲的情况
        {
            if (flags > CameraClearFlags.Color)//color是2，只清depth或什么都不清是3或4
            {
                flags = CameraClearFlags.Color;//这个相机如果只清深度，或什么都不清，如果要应用后处理，就得把颜色和深度都强制清掉
            }
            
            //若有后处理启用，把渲染目标设为临时纹理，而非屏幕，所以，DrawVisibleGeometry(),DrawUnsupportedShaders(),DrawGizmosBeforeFX()此时都只画在"_CameraFrameBuffer"上
            
            //把frameBufferId的单独的帧缓冲区纹理拆成颜色和深度
            buffer.GetTemporaryRT(colorAttachmentId, bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
                useHDR ? RenderTextureFormat.DefaultHDR : RenderTextureFormat.Default);//是否启用HDR只对后处理堆栈有影响，因此在这决定RT的格式
            // buffer.GetTemporaryRT(depthAttachmentId, bufferSize.x, bufferSize.y, 32, FilterMode.Point,
            //     RenderTextureFormat.Depth);
            buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
                gDepthId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);//设置渲染目标的时候，这样写，就是两张纹理共享一个帧缓冲区
            //原来的写法：buffer.SetRenderTarget(frameBufferId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);//是一张纹理一个帧缓冲区
        }
        
        buffer.ClearRenderTarget(
            flags <= CameraClearFlags.Depth, //除了清除标识为nothing以外都要清除深度缓冲
            flags <= CameraClearFlags.Color, 
            flags == CameraClearFlags.Color ? camera.backgroundColor.linear : Color.clear);//如果清除标志就是颜色，那么填入相机的清除颜色
        buffer.BeginSample("Setup");
        buffer.SetGlobalTexture(colorTextureId, missingTexture);//默认空纹理占位，避免未启用时shader报错
        //buffer.SetGlobalTexture(depthTextureId, missingTexture);
        ExecuteBuffer();
    }

    ///我们向上下文context发送的命令都是缓冲的，要在context调用submit提交，排队的工作才会执行
    ///类似OpenGL的一次draw
    void Submit()
    {
        buffer.EndSample(SampleName);
        ExecuteBuffer();
        context.Submit();
    }
    
    ///绘制某些东西有专门的函数，大部分内容要用cmd执行，还要多次复用，这里提供执行后clear而不release的方法
    void ExecuteBuffer()
    {
        context.ExecuteCommandBuffer(buffer);
        buffer.Clear();
    }
    
    //定义Shader
    private static ShaderTagId unlitShaderTagId = new ShaderTagId("SRPDefaultUnlit"), //无光照shader
        litShaderTagId = new ShaderTagId("ArgonaraLit"),
        gBufferShaderTagId = new ShaderTagId("ArgonaraGBuffer");

    void CreateGBuffers()
    {
        //声明和创建GBuffer纹理
        buffer.GetTemporaryRT(gDepthId, bufferSize.x, bufferSize.y, 32, FilterMode.Point, RenderTextureFormat.Depth,
            RenderTextureReadWrite.Linear); //深度图
        buffer.GetTemporaryRT(gBuffersId[0], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
            RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear); //GT1，xyz是颜色
        buffer.GetTemporaryRT(gBuffersId[1], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
            RenderTextureFormat.ARGB2101010, RenderTextureReadWrite.Linear); //GT2，xyz是法线
        buffer.GetTemporaryRT(gBuffersId[2], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
            RenderTextureFormat.ARGB64, RenderTextureReadWrite.Linear); //GT3，xy是运动向量，zw是smoothness,metallic
        buffer.GetTemporaryRT(gBuffersId[3], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
            RenderTextureFormat.ARGBFloat, RenderTextureReadWrite.Linear); //GT4，xyz是emission，w是occlusion
        buffer.GetTemporaryRT(gBuffersId[4], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
            RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear); //GT5，目前暂时存在，xyz是indirect diffuse

    }
    
    void DrawGBuffers()
    {
        //声明和创建GBuffer纹理
        // buffer.GetTemporaryRT(gDepthId, bufferSize.x, bufferSize.y, 32, FilterMode.Point, RenderTextureFormat.Depth, RenderTextureReadWrite.Linear);                //深度图
        // buffer.GetTemporaryRT(gBuffersId[0], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);        //GT1，xyz是颜色
        // buffer.GetTemporaryRT(gBuffersId[1], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear, RenderTextureFormat.ARGB2101010, RenderTextureReadWrite.Linear);   //GT2，xyz是法线
        // buffer.GetTemporaryRT(gBuffersId[2], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear, RenderTextureFormat.ARGB64, RenderTextureReadWrite.Linear);        //GT3，xy是运动向量，zw是smoothness,metallic
        // buffer.GetTemporaryRT(gBuffersId[3], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear, RenderTextureFormat.ARGBFloat, RenderTextureReadWrite.Linear);     //GT4，xyz是emission，w是occlusion
        // buffer.GetTemporaryRT(gBuffersId[4], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);        //GT5，目前暂时存在，xyz是indirect diffuse
        
        buffer.SetRenderTarget(new RenderTargetIdentifier[] {gBuffersId[0], gBuffersId[1], gBuffersId[2], gBuffersId[3], gBuffersId[4]}, gDepthId);
        buffer.ClearRenderTarget(true, true, Color.clear);
        buffer.name = "GBuffer";
        buffer.BeginSample("GBuffer");
        ExecuteBuffer();
    }
    
    ///绘制可见几何体
    void DrawVisibleGeometry(bool useDynamicBatching, bool useGPUInsancing, bool useLightsPerObject,
        int renderingLayerMask)
    {
        PerObjectData lightsPerObjectFlags = useLightsPerObject ? PerObjectData.LightData | PerObjectData.LightIndices : PerObjectData.None;//若启用逐对象光照，则传递逐物体的光照信息和光源索引
        //绘制opaque物体
        var sortingSettings = new SortingSettings(camera)
        {
            criteria = SortingCriteria.CommonOpaque
        };
        var gBufferDrawingSettings = new DrawingSettings(gBufferShaderTagId, sortingSettings)
        {
            enableDynamicBatching = useDynamicBatching,//开启动态批处理,把材质相同的多个小网格合并成一个大网格，减少drawcalls
            enableInstancing = useGPUInsancing,
            perObjectData = PerObjectData.ReflectionProbes |
                            PerObjectData.Lightmaps |
                            PerObjectData.ShadowMask |
                            PerObjectData.LightProbe | 
                            PerObjectData.OcclusionProbe |
                            PerObjectData.LightProbeProxyVolume |
                            PerObjectData.OcclusionProbeProxyVolume |
                            lightsPerObjectFlags
        };
        var filteringSettings = new FilteringSettings(RenderQueueRange.opaque, renderingLayerMask: (uint)renderingLayerMask);
        
        //为Opaque Lit写入GBuffer
        //DrawGBuffers();
        buffer.SetRenderTarget(
            new RenderTargetIdentifier[] { gBuffersId[0], gBuffersId[1], gBuffersId[2], gBuffersId[3], gBuffersId[4] },
            gDepthId);
        buffer.ClearRenderTarget(true, true, Color.clear);
        buffer.name = "GBuffer";
        buffer.BeginSample("GBuffer");
        ExecuteBuffer();
        context.DrawRenderers(cullingResults,ref gBufferDrawingSettings, ref filteringSettings);
        ExecuteBuffer();
        
        //将GBuffer传入GPU
        //buffer.SetGlobalTexture(gDepthId, gDepthId);
        CopyDepthAttachments();//不应该在这复制深度
        buffer.SetGlobalTexture(depthTextureId, depthTextureId);
        foreach(var gBufferId in gBuffersId)
            buffer.SetGlobalTexture(gBufferId, gBufferId);
        
        //恢复渲染目标回colorTexture
        buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
            gDepthId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        ExecuteBuffer();

        //为Opaque Lit执行光照计算——全屏三角，读取GBuffer，输出到colorAttachment
        
        buffer.DrawProcedural(Matrix4x4.identity, material, 2, MeshTopology.Triangles, 3);
        buffer.name = "Deferred Lighting";
        buffer.BeginSample("Deferred Lighting");
        buffer.EndSample("Deferred Lighting");
        buffer.EndSample("GBuffer");
        buffer.name = bufferName;
        ExecuteBuffer();

        //恢复渲染目标回colorTexture，它存的应该是经过光照计算的opaque lit+opaque unlit的结果
        // buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
        //     gDepthId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        // ExecuteBuffer();

        //画opaque unlit——新建DrawingSettings，base pass用unlitShaderTagId
        var unlitDrawingSettings = new DrawingSettings(unlitShaderTagId, sortingSettings)
        {
            enableDynamicBatching = useDynamicBatching,
            enableInstancing = useGPUInsancing,
            perObjectData = PerObjectData.ReflectionProbes |
                            PerObjectData.Lightmaps |
                            PerObjectData.ShadowMask |
                            PerObjectData.LightProbe | 
                            PerObjectData.OcclusionProbe |
                            PerObjectData.LightProbeProxyVolume |
                            PerObjectData.OcclusionProbeProxyVolume |
                            lightsPerObjectFlags
        };
        context.DrawRenderers(cullingResults, ref unlitDrawingSettings, ref filteringSettings);
        
        //绘制天空盒
        context.DrawSkybox(camera);//关于它，为什么相机标记为clearFlags为color时看不到天空盒？明明天空盒在默认颜色之后渲染，也不清除天空盒，为啥只能看到颜色？，，，发现clearFlags为color的时候，帧调试器里没有drawSkybox，那就是自动跳过了，大概率是底层C++固定做的判断
        
        if (useColorTexture)
        {
            CopyAttachments();
            CopyDepthAttachments();
        }
        
        //先绘制opaque，再绘制skybox，然后绘制transparent   避免skybox盖住半透物体
        //trans的排序用CommonTransparent，从后往前绘制，和opaque的前往后相反
        //trans咋排序对性能没影响+必须从后往前才有可能正确混合。
        //但如此不能保证正确混合，因为排序是基于对象的位置，针对每个对象排序的。交叉和大的trans物体还是可能错误排序，或许可以把大物体切割成多个小物体来尝试接近，，，能这样干吗？
        sortingSettings.criteria = SortingCriteria.CommonTransparent;
        unlitDrawingSettings.sortingSettings = sortingSettings;
        unlitDrawingSettings.SetShaderPassName(1, litShaderTagId);
        filteringSettings.renderQueueRange = RenderQueueRange.transparent;//就是靠这句判断是不是transparent，对于deferred，opaque lit和opaque clip lit写入GBuffer，transparent lit和其他trans搁这
        context.DrawRenderers(cullingResults,ref unlitDrawingSettings, ref filteringSettings);
    }

    ///用于释放申请的纹理等
    void Cleanup()
    {
        lighting.Cleanup();
        if (useIntermediateBuffer)
        {
            buffer.ReleaseTemporaryRT(colorAttachmentId);
            //buffer.ReleaseTemporaryRT(depthAttachmentId);
            if (useColorTexture)
            {
                buffer.ReleaseTemporaryRT(colorTextureId);
            }
        }
        buffer.ReleaseTemporaryRT(depthTextureId);

        buffer.ReleaseTemporaryRT(gDepthId);
        for (int i = 0; i < gBuffersId.Length; i++) 
            buffer.ReleaseTemporaryRT(gBuffersId[i]);
    }

    static bool copyTextureSupported = SystemInfo.copyTextureSupport > CopyTextureSupport.None; 
    
    void CopyAttachments()
    {
        //颜色纹理拷贝（折射/扭曲等透明物体需要）
        if (useColorTexture)
        {
            buffer.GetTemporaryRT(colorTextureId, bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
                useHDR ? RenderTextureFormat.DefaultHDR : RenderTextureFormat.Default);
            if (copyTextureSupported)
            {
                buffer.CopyTexture(colorAttachmentId, colorTextureId);
            }
            else
            {
                Draw(colorAttachmentId, colorTextureId);
            }
        }
        if (!copyTextureSupported)
        {
            buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
                gDepthId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);//Draw改了渲染目标，统一恢复
        }
        ExecuteBuffer();
    }

    void CopyDepthAttachments()
    {
        //深度纹理拷贝（软粒子等需要）
        if (true)
        {
            buffer.GetTemporaryRT(depthTextureId, bufferSize.x, bufferSize.y, 32, FilterMode.Point,
                RenderTextureFormat.Depth);
            if (copyTextureSupported)
            {
                buffer.CopyTexture(gDepthId, depthTextureId);
            }
            else
            {
                Draw(gDepthId, depthTextureId, true);
            }
        }
        if (!copyTextureSupported)
        {
            buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
                gDepthId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store); //Draw改了渲染目标，统一恢复
        }

        ExecuteBuffer();
    }

    Material material;

    Texture2D missingTexture;//因为深度纹理是可选的，所以需要一个缺失的纹理，来避免没有深度纹理时的错误
    
    public CameraRendererDeferred(Shader shader)
    {
        material = CoreUtils.CreateEngineMaterial(shader);//创建一个材质并隐藏，不会保存为资产
        missingTexture = new Texture2D(1, 1)
        {
            hideFlags = HideFlags.HideAndDontSave, name = "Missing"
        };
        missingTexture.SetPixel(0, 0, Color.white * 0.5f);
        missingTexture.Apply(true, true);
    }

    public override void Dispose()
    {
        CoreUtils.Destroy(material);
        CoreUtils.Destroy(missingTexture);
    }

    static Rect fullViewRect = new Rect(0f, 0f, 1f, 1f);

    void Draw(RenderTargetIdentifier from, RenderTargetIdentifier to, bool isDepth = false)
    {
        buffer.SetGlobalTexture(sourceTextureId, from);
        buffer.SetRenderTarget(to, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, material, isDepth ? 1 : 0, MeshTopology.Triangles, 3);
    }

    void DrawFinal(CameraSettings.FinalBlendMode finalBlendMode)
    {
        buffer.SetGlobalFloat(srcBlendId, (float)finalBlendMode.source);
        buffer.SetGlobalFloat(dstBlendId, (float)finalBlendMode.destination);
        buffer.SetGlobalTexture(sourceTextureId, colorAttachmentId);//源始终是颜色附件
        buffer.SetRenderTarget(BuiltinRenderTextureType.CameraTarget,
            finalBlendMode.destination == BlendMode.Zero && camera.rect == fullViewRect ?
                RenderBufferLoadAction.DontCare : RenderBufferLoadAction.Load,
            RenderBufferStoreAction.Store);
        buffer.SetViewport(camera.pixelRect);
        buffer.DrawProcedural(Matrix4x4.identity, material, 0, MeshTopology.Triangles, 3);
        buffer.SetGlobalFloat(srcBlendId, 1f);//重置混合模式，不影响后续其他Draw调用
        buffer.SetGlobalFloat(dstBlendId, 0f);
    }
}
