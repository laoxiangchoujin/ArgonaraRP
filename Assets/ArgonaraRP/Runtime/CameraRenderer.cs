using UnityEngine;
using UnityEngine.Rendering;

///RenderPipeline需要按顺序处理每个相机，把这个责任转交给此类
///它大致相当于URP的scriptable renderer
//这种方法，让每个相机在未来更容易支持不同的渲染方法，如一个渲染第一人称视图，一个渲染三维地图，或前向和延迟渲染
public partial class CameraRenderer
{
    ScriptableRenderContext context;
    
    Camera camera;

    private const string bufferName = "Render Camera";

    private CommandBuffer buffer = new CommandBuffer
    {
        name = bufferName
    };

    Lighting lighting = new Lighting();
    
    PostFXStack postFXStack = new PostFXStack();//堆栈实例

    bool useHDR;

    static CameraSettings defaultCameraSettings = new CameraSettings();//没有挂组件的相机用默认设置

    bool useColorTexture, useDepthTexture, 
        useIntermediateBuffer;
    
    ///绘制相机能看到的所有几何图形
    public void Render(ScriptableRenderContext context, Camera camera, CameraBufferSettings bufferSettings,
        bool useDynamicBatching, bool useGPUInsancing, bool useLightsPerObject, 
        ShadowSettings shadowSettings, PostFXSettings postFXSettings, int colorLUTResolution)
    {
        this.context = context;
        this.camera = camera;

        var argonaraRPCamera = camera.GetComponent<ArgonaraRenderPipelineCamera>();//尝试在场景里真的存在的Camera相机上，找到我的自定义的，设置相机final pass混合模式的组件    这一步只对PostFx的final pass有影响
        CameraSettings cameraSettings = argonaraRPCamera ? argonaraRPCamera.Settings : defaultCameraSettings;//没找到就默认One,Zero，，，覆写的要用One,OneMinusSrcAlpha

        //实时反射探针每帧6次渲染，开销大→单独开关；主相机和SceneView由管线+相机双重开关控制
        if (camera.cameraType == CameraType.Reflection)
        {
            useColorTexture = bufferSettings.copyColorReflection;
            useDepthTexture = bufferSettings.copyDepthReflection;
        }
        else
        {
            useColorTexture = bufferSettings.copyColor && cameraSettings.copyColor;
            useDepthTexture = bufferSettings.copyDepth && cameraSettings.copyDepth;
        }
        
        if (cameraSettings.overridePostFX)
        {
            postFXSettings = cameraSettings.postFXSettings;//相机自己的后处理设置覆盖管线全局设置
        }

        PrepareBuffer();
        PrepareForSceneWindow();//给scene view里的UI物体添加到世界几何体中，因为可能会为场景增加一些几何体，所以要在剔除前做
        if (!Cull(shadowSettings.maxDistance))
        {
            return;
        }
        
        useHDR = bufferSettings.allowHDR && camera.allowHDR;//HDR双控：管线全局开关 + 相机自身开关
        
        //如果给lighting一个专门的sample，可以在主相机claer之前，把阴影项嵌套在main camera中
        buffer.BeginSample(SampleName);
        ExecuteBuffer();
        lighting.Setup(context, cullingResults, shadowSettings, useLightsPerObject,
            cameraSettings.maskLights ? cameraSettings.renderingLayerMask : -1);//相机可选的灯光渲染层过滤
        postFXStack.Setup(context, camera, postFXSettings, useHDR, colorLUTResolution, cameraSettings.finalBlendMode);
        buffer.EndSample(SampleName);
        
        Setup();//lighting的Setup包含了shadows的render指令，先渲染阴影，然后在此做相机的主进程   //第二个beginSample
        DrawVisibleGeometry(useDynamicBatching, useGPUInsancing, useLightsPerObject,
            cameraSettings.renderingLayerMask);
        DrawUnsupportedShaders();
        
        //lighting.Cleanup();//在提交之前，清空shadowmap

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
    
    ///应该是CPU的视锥剔除
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

    //相机帧缓冲纹理的id
    //private static int frameBufferId = Shader.PropertyToID("_CameraFrameBuffer");
    
    //原来合并的一张的帧缓冲区纹理，frameBufferId，拆成两张，颜色和深度，为了处理“半透明阶段需要不透明物体的深度”的问题
    //这里既然说attachment，附件啊，那就是，不一定直接用于最后的半透明读取，很可能是作为写入值的中间纹理，然后再copy到用于读取的最终纹理
    static int colorAttachmentId = Shader.PropertyToID("_CameraColorAttachment");
    static int depthAttachmentId = Shader.PropertyToID("_CameraDepthAttachment");
    static int colorTextureId = Shader.PropertyToID("_CameraColorTexture");
    static int depthTextureId = Shader.PropertyToID("_CameraDepthTexture");
    static int sourceTextureId = Shader.PropertyToID("_SourceTexture");
    static int srcBlendId = Shader.PropertyToID("_CameraSrcBlend");
    static int dstBlendId = Shader.PropertyToID("_CameraDstBlend");
    
    ///将相机的属性应用于上下文context
    void Setup()
    {
        context.SetupCameraProperties(camera); //渲染前设置正确的相机矩阵unity_MatrixVP
        CameraClearFlags flags = camera.clearFlags;//它有4个值，1~4是Skybox,Color,Depth,Nothing，

        useIntermediateBuffer = useColorTexture || useDepthTexture || postFXStack.IsActive;
        if (useIntermediateBuffer)//若要执行FX堆栈，则需要获取帧缓冲
        {
            if (flags > CameraClearFlags.Color)//color是2，只清depth或什么都不清是3或4
            {
                flags = CameraClearFlags.Color;//这个相机如果只清深度，或什么都不清，如果要应用后处理，就得把颜色和深度都强制清掉
            }
            
            //若有后处理启用，把渲染目标设为临时纹理，而非屏幕，所以，DrawVisibleGeometry(),DrawUnsupportedShaders(),DrawGizmosBeforeFX()此时都只画在"_CameraFrameBuffer"上
            
            //把frameBufferId的单独的帧缓冲区纹理拆成颜色和深度
            buffer.GetTemporaryRT(colorAttachmentId, camera.pixelWidth, camera.pixelHeight, 0, FilterMode.Bilinear,
                useHDR ? RenderTextureFormat.DefaultHDR : RenderTextureFormat.Default);//是否启用HDR只对后处理堆栈有影响，因此在这决定RT的格式
            buffer.GetTemporaryRT(depthAttachmentId, camera.pixelWidth, camera.pixelHeight, 32, FilterMode.Point,
                RenderTextureFormat.Depth);
            buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
                depthAttachmentId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);//设置渲染目标的时候，这样写，就是两张纹理共享一个帧缓冲区
            //原来的写法：buffer.SetRenderTarget(frameBufferId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);//是一张纹理一个帧缓冲区
        }
        
        buffer.ClearRenderTarget(
            flags < CameraClearFlags.Nothing, //除了清除标识为nothing以外都要清除深度缓冲
            flags <= CameraClearFlags.Color, 
            flags == CameraClearFlags.Color ? camera.backgroundColor.linear : Color.clear);//如果清除标志就是颜色，那么填入相机的清除颜色
        buffer.BeginSample(SampleName);
        buffer.SetGlobalTexture(colorTextureId, missingTexture);//默认空纹理占位，避免未启用时shader报错
        buffer.SetGlobalTexture(depthTextureId, missingTexture);
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
        litShaderTagId = new ShaderTagId("ArgonaraLit");

    
    
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
        var drawingSettings = new DrawingSettings(unlitShaderTagId, sortingSettings)
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
        drawingSettings.SetShaderPassName(1, litShaderTagId);
        var filteringSettings = new FilteringSettings(RenderQueueRange.opaque, renderingLayerMask: (uint)renderingLayerMask);
        context.DrawRenderers(cullingResults,ref drawingSettings, ref filteringSettings);
        
        //绘制天空盒，原本是context.DrawSkybox(camera);但说已过时
        //下边五行的逻辑很清晰，context创建一个renderList，创建cmd，cmd要画renderlist，context执行cmd，删掉cmd
        // RendererList skyboxRendererList = context.CreateSkyboxRendererList(camera);
        // CommandBuffer cmd = new CommandBuffer { name = "Draw Skybox" };
        // cmd.DrawRendererList(skyboxRendererList);
        // context.ExecuteCommandBuffer(cmd);
        // cmd.Release();
        context.DrawSkybox(camera);//关于它，为什么相机标记为clearFlags为color时看不到天空盒？明明天空盒在默认颜色之后渲染，也不清除天空盒，为啥只能看到颜色？，，，发现clearFlags为color的时候，帧调试器里没有drawSkybox，那就是自动跳过了，大概率是底层C++固定做的判断
        
        if (useColorTexture || useDepthTexture)
        {
            CopyAttachments();
        }
        
        //先绘制opaque，再绘制skybox，然后绘制transparent   避免skybox盖住半透物体
        //trans的排序用CommonTransparent，从后往前绘制，和opaque的前往后相反
        //trans咋排序对性能没影响+必须从后往前才有可能正确混合。
        //但如此不能保证正确混合，因为排序是基于对象的位置，针对每个对象排序的。交叉和大的trans物体还是可能错误排序，或许可以把大物体切割成多个小物体来尝试接近，，，能这样干吗？
        sortingSettings.criteria = SortingCriteria.CommonTransparent;
        drawingSettings.sortingSettings = sortingSettings;
        filteringSettings.renderQueueRange = RenderQueueRange.transparent;
        context.DrawRenderers(cullingResults,ref drawingSettings, ref filteringSettings);
    }

    ///用于释放申请的纹理等
    void Cleanup()
    {
        lighting.Cleanup();
        if (useIntermediateBuffer)
        {
            buffer.ReleaseTemporaryRT(colorAttachmentId);
            buffer.ReleaseTemporaryRT(depthAttachmentId);
            if (useColorTexture)
            {
                buffer.ReleaseTemporaryRT(colorTextureId);
            }
            if (useDepthTexture)
            {
                buffer.ReleaseTemporaryRT(depthTextureId);
            }
        }
    }

    static bool copyTextureSupported = SystemInfo.copyTextureSupport > CopyTextureSupport.None; 
    
    void CopyAttachments()
    {
        //颜色纹理拷贝（折射/扭曲等透明物体需要）
        if (useColorTexture)
        {
            buffer.GetTemporaryRT(colorTextureId, camera.pixelWidth, camera.pixelHeight, 0, FilterMode.Bilinear,
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
        //深度纹理拷贝（软粒子等需要）
        if (useDepthTexture)
        {
            buffer.GetTemporaryRT(depthTextureId, camera.pixelWidth, camera.pixelHeight, 32, FilterMode.Point, RenderTextureFormat.Depth);
            if (copyTextureSupported)
            {
                buffer.CopyTexture(depthAttachmentId, depthTextureId);
            }
            else
            {
                Draw(depthAttachmentId, depthTextureId, true);
            }
        }
        if (!copyTextureSupported)
        {
            buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
                depthAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);//Draw改了渲染目标，统一恢复
        }
        ExecuteBuffer();
    }

    Material material;

    Texture2D missingTexture;//因为深度纹理是可选的，所以需要一个缺失的纹理，来避免没有深度纹理时的错误
    
    public CameraRenderer(Shader shader)
    {
        material = CoreUtils.CreateEngineMaterial(shader);//创建一个材质并隐藏，不会保存为资产
        missingTexture = new Texture2D(1, 1)
        {
            hideFlags = HideFlags.HideAndDontSave, name = "Missing"
        };
        missingTexture.SetPixel(0, 0, Color.white * 0.5f);
        missingTexture.Apply(true, true);
    }

    public void Dispose()
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
