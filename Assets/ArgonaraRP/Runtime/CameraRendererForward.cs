using UnityEngine;
using UnityEngine.Rendering;

///RenderPipeline需要按顺序处理每个相机，把这个责任转交给此类
///它大致相当于URP的scriptable renderer
//这种方法，让每个相机在未来更容易支持不同的渲染方法，如一个渲染第一人称视图，一个渲染三维地图，或前向和延迟渲染
public partial class CameraRendererForward : CameraRendererBase
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

    bool useHDR, useScaleRendering;

    private Vector2Int bufferSize;

    static CameraSettings defaultCameraSettings = new CameraSettings();//没有挂组件的相机用默认设置

    bool useColorTexture, useDepthTexture, 
        useIntermediateBuffer;

    //颜色快照要建几级mip（1 = 不建链）。在Render开头算好存这里：
    //拷颜色那几个函数里拿不到 bufferSettings（它只是Render的参数）和 bufferSize，所以只能先算一手
    int colorMipCount = 1;
    
    public const float renderScaleMin = 0.1f, renderScaleMax = 2f;
    
    ///绘制相机能看到的所有几何图形
    public override void Render(ScriptableRenderContext context, Camera camera, CameraBufferSettings bufferSettings,
        bool useDynamicBatching, bool useGPUInsancing, bool useLightsPerObject,
        ShadowSettings shadowSettings, SSRSettings ssrSettings, PostFXSettings postFXSettings, int colorLUTResolution)
    {
        //ssrSettings：转给 Setup（那边交给 ScreenSpaceReflection 处理：判定/建图/绑 _SSRTex/传参）
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

        //SSR 的 trace 要用"不透明+天空盒"的颜色快照和深度图（ScreenSpaceReflection.hlsl 里直接采
        //_CameraColorTexture / _CameraDepthTexture）⇒ 它一旦要走，这两份拷贝就必须打开。
        //否则 _SSRTex 会去采 Setup 里绑的 missingTexture 占位灰图（看着像"开了SSR却坏了"）。
        if (ScreenSpaceReflection.ShouldRender(ssrSettings, camera))
        {
            useColorTexture = true;
            useDepthTexture = true;
        }
        
        if (cameraSettings.overridePostFX)
        {
            postFXSettings = cameraSettings.postFXSettings;//相机自己的后处理设置覆盖管线全局设置
        }

        float renderScale = cameraSettings.GetRenderScale(bufferSettings.renderScale);
        useScaleRendering = renderScale < 0.99f || renderScale > 1.01f;
        PrepareBuffer();
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
        
        //颜色快照的mip级数（这相机压根不拷颜色就按1算，反正不会建那张图）
        colorMipCount = useColorTexture ?
            CameraRendererBase.GetColorMipCount(bufferSettings, bufferSize.x, bufferSize.y) : 1;
        
        //如果给lighting一个专门的sample，可以在主相机claer之前，把阴影项嵌套在main camera中
        buffer.BeginSample(SampleName);
        buffer.SetGlobalVector(bufferSizeId, new Vector4(1f/bufferSize.x, 1f/bufferSize.y, bufferSize.x, bufferSize.y));//渲染缩放后，替代_ScreenParams
        ExecuteBuffer();
        lighting.Setup(context, camera, cullingResults, shadowSettings, useLightsPerObject,
            cameraSettings.maskLights ? cameraSettings.renderingLayerMask : -1);//相机可选的灯光渲染层过滤
        postFXStack.Setup(context, camera, bufferSize, postFXSettings, useHDR, colorLUTResolution, cameraSettings.finalBlendMode, bufferSettings.bicubicRescaling);
        buffer.EndSample(SampleName);
        
        Setup(shadowSettings, ssrSettings);//lighting的Setup包含了shadows的render指令，先渲染阴影，然后在此做相机的主进程   //第二个beginSample
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
    //深度法线prepass（屏幕空间阴影/SSAO用）的法线图：与延迟的GBuffer2同用途，只是名字不同
    static int normalsTextureId = Shader.PropertyToID("_CameraNormalsTexture");
    //告诉shader"当前是前向还是延迟"（1=延迟、0=前向）：用于区分"用途相同但名字不同"的纹理
    static int useDeferredRendererId = Shader.PropertyToID("_UseDeferredRenderer");

    //屏幕空间阴影（第3步）的**两对**图：结果图+倒手图半分辨率、半影mask+倒手图1/4分辨率；都是R8
    //（和延迟那边同名同义，shader 才能共用）
    static int screenSpaceShadowTexId = Shader.PropertyToID("_ScreenSpaceShadowTex");
    //结果图的blur倒手图：同一张纹理不能在同一次绘制里既读又写，所以横/竖两趟之间来回倒一次（半分辨率）
    static int screenSpaceShadowTexTempBlurId = Shader.PropertyToID("_ScreenSpaceShadowTex_TempBlur");
    //半影mask（akg/原神那套）：1/4分辨率、一个纹素对应4×4个屏幕像素，只标记"阴影/半影/非阴影"三态。
    //有了它，PCSS就只在半影带里跑（其余像素直接返回0或1），mask自己那两趟blur也从"给PCSS去噪"变成"扩宽半影带"
    static int screenSpaceShadowMaskTexId = Shader.PropertyToID("_ScreenSpaceShadowMaskTex");
    //mask自己的blur倒手图：1/4分辨率（和结果图的倒手图不是一套尺寸，不能共用）
    static int screenSpaceShadowMaskTexTempId = Shader.PropertyToID("_ScreenSpaceShadowMaskTexTemp");
    //【mask那一对】的纹素尺寸（xy = 1/宽、1/高）：mask blur取邻居用它，mask那趟还靠它反推"1个屏幕像素"
    static int screenSpaceShadowTexelSizeId = Shader.PropertyToID("_ScreenSpaceShadowTexelSize");
    //【结果图那一对】的纹素尺寸：结果图那两趟双边blur取邻居用它（结果图是半分辨率，和mask不是一套尺寸）
    static int screenSpaceShadowResultTexelSizeId = Shader.PropertyToID("_ScreenSpaceShadowResultTexelSize");
    //本帧是否走屏幕空间阴影：在 Setup 里按设置定下，Cleanup 用同一个值配对释放
    bool useScreenSpaceShadow;
    //告诉光照shader"这之后画的物体采样屏幕空间阴影图"（和延迟那边同名同义）
    static int screenSpaceShadowEnabledId = Shader.PropertyToID("_ScreenSpaceShadowEnabled");
    static int sourceTextureId = Shader.PropertyToID("_SourceTexture");
    static int srcBlendId = Shader.PropertyToID("_CameraSrcBlend");
    static int dstBlendId = Shader.PropertyToID("_CameraDstBlend");

    //=========================== SSR（屏幕空间反射）===========================
    //本帧走不走 SSR 由**这里**判定：公共部分用 ScreenSpaceReflection.ShouldRender；
    //前向的附加需求（颜色快照 + 深度图）在 Render 开头就按 SSR 强制打开了 ⇒ 判定不再有额外条件
    //建图/绑 _SSRTex/那三趟绘制/释放都在 ScreenSpaceReflection 里（两个渲染器共用一份实现）
    ScreenSpaceReflection ssr = new ScreenSpaceReflection();
    bool useSSR;

    //=========================== Hi-Z（分层深度图）===========================
    //SSR 的追踪用它决定步长（安全就升 mip、碰到就退一级 ⇒ 比线性步进快得多）。它的设置挂在 SSR 设置里（ssrSettings.hiz）。
    //建图/逐级降采样/释放都在 HierarchicalZ 里，这里只管**时机**：
    //  Setup：和 ssr.Setup 挨着（建图 + 传参数，不碰渲染目标）
    //  Draw：紧挨着 ssr.Draw 之前（此刻深度图完整、反射源也齐了）
    HierarchicalZ hiz = new HierarchicalZ();

    private static int bufferSizeId = Shader.PropertyToID("_CameraBufferSize");//因为unity默认提供的_ScreenParams数值不会随我们的渲染缩放调整，需要自己传值替代
    
    ///将相机的属性应用于上下文context
    void Setup(ShadowSettings shadowSettings, SSRSettings ssrSettings)
    {
        context.SetupCameraProperties(camera); //渲染前设置正确的相机矩阵unity_MatrixVP
        //手动设置 unity_MatrixInvVP（SetupCameraProperties 可能不设它）：屏幕空间阴影要用它从深度重建世界坐标
        Matrix4x4 view = camera.worldToCameraMatrix;
        Matrix4x4 proj = GL.GetGPUProjectionMatrix(camera.projectionMatrix, true);
        buffer.SetGlobalMatrix(Shader.PropertyToID("unity_MatrixInvVP"), (proj * view).inverse);

        //本帧是否走屏幕空间阴影（第3步）：PCSS总开关 + 屏幕空间开关都开着、并且配了shader才走。
        //为什么必须带上 pcss.enabled：屏幕空间那套只是"实现PCSS的一种方式"（算完写张图让光照Pass采）。
        //PCSS 关掉时材质走的是普通PCF、根本不采这张图（采样的门是 _ScreenSpaceShadowEnabled，它看的正是这个变量），
        //再不门控就会"白建4张图 + 白跑5趟"（开关独立时就会出现：没开PCSS却还在blur）。
        useScreenSpaceShadow = shadowSettings.directional.pcss.enabled &&
                               shadowSettings.directional.pcss.screenSpaceBlur && screenSpaceShadowMaterial;

        //本帧走不走 SSR：公共判定（总开关 / Material / 排除反射相机）。
        //前向没有附加条件了：SSR 依赖的"颜色快照 + 深度图"在 Render 开头已经按 SSR 强制打开（见那边）
        useSSR = ScreenSpaceReflection.ShouldRender(ssrSettings, camera);

        //交给 SSR 自己（**每帧都调**，真/假两种走向都在里面）：建(重建)两张持久图 + 绑 _SSRTex(上一帧那张)
        //+ 上传调参；关掉那帧则是释放两张持久图 + 绑 1×1 纯黑（不执行的话本帧会采到上一帧那张不该再用的图）。
        //⚠️ 必须放在下面"设成颜色附件+深度"之前：建图那几帧里会清图、把渲染目标设成 SSR 图。
        ssr.Setup(buffer, ssrSettings, useSSR, bufferSize.x, bufferSize.y, useHDR);

        //HiZ：同样**每帧都调**（不走时在里面释放主图 + 绑黑图兜底）。useSSR 为假就不用建它（眼下只有 SSR 会用）
        hiz.Setup(buffer, ssrSettings?.hiz, useSSR, bufferSize.x, bufferSize.y);

        CameraClearFlags flags = camera.clearFlags;//它有4个值，1~4是Skybox,Color,Depth,Nothing，

        //屏幕空间阴影需要"可读的深度"和自己的RT，所以也强制走中间缓冲
        useIntermediateBuffer = useScaleRendering || 
                                useColorTexture || useDepthTexture || postFXStack.IsActive || useScreenSpaceShadow;
        if (useIntermediateBuffer)//若要执行FX堆栈，则需要获取帧缓冲
        {
            if (flags > CameraClearFlags.Color)//color是2，只清depth或什么都不清是3或4
            {
                flags = CameraClearFlags.Color;//这个相机如果只清深度，或什么都不清，如果要应用后处理，就得把颜色和深度都强制清掉
            }
            
            //若有后处理启用，把渲染目标设为临时纹理，而非屏幕，所以，DrawVisibleGeometry(),DrawUnsupportedShaders(),DrawGizmosBeforeFX()此时都只画在"_CameraFrameBuffer"上
            
            //把frameBufferId的单独的帧缓冲区纹理拆成颜色和深度
            buffer.GetTemporaryRT(colorAttachmentId, bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
                useHDR ? RenderTextureFormat.DefaultHDR : RenderTextureFormat.Default);//是否启用HDR只对后处理堆栈有影响，因此在这决定RT的格式
            buffer.GetTemporaryRT(depthAttachmentId, bufferSize.x, bufferSize.y, 32, FilterMode.Point,
                RenderTextureFormat.Depth);
            buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
                depthAttachmentId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);//设置渲染目标的时候，这样写，就是两张纹理共享一个帧缓冲区
            //原来的写法：buffer.SetRenderTarget(frameBufferId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);//是一张纹理一个帧缓冲区
        }
        
        //深度法线prepass要用的法线图（屏幕空间阴影/SSAO）：目前始终创建，先不管条件
        buffer.GetTemporaryRT(normalsTextureId, bufferSize.x, bufferSize.y, 0, FilterMode.Point,
            RenderTextureFormat.ARGB2101010, RenderTextureReadWrite.Linear);
        buffer.SetGlobalTexture(normalsTextureId, normalsTextureId);
        //这是前向渲染器
        buffer.SetGlobalInt(useDeferredRendererId, 0);

        //屏幕空间阴影（第3步）的两张半分辨率图：开关关掉就不创建
        AllocateScreenSpaceShadowTextures();

        buffer.ClearRenderTarget(
            flags < CameraClearFlags.Nothing, //除了清除标识为nothing以外都要清除深度缓冲
            flags <= CameraClearFlags.Color, 
            flags == CameraClearFlags.Color ? camera.backgroundColor.linear : Color.clear);//如果清除标志就是颜色，那么填入相机的清除颜色
        buffer.BeginSample(SampleName);
        buffer.SetGlobalTexture(colorTextureId, missingTexture);//默认空纹理占位，避免未启用时shader报错
        buffer.SetGlobalTexture(depthTextureId, missingTexture);
        ExecuteBuffer();
    }

    //屏幕空间阴影（第3步）的**两对**图：结果图+倒手图半分辨率、半影mask+倒手图1/4分辨率；开关关掉就什么都不创建
    void AllocateScreenSpaceShadowTextures()
    {
        if (!useScreenSpaceShadow)
        {
            return;
        }

        //结果图 + 它的倒手图：半分辨率（PCSS采样和blur都省4倍），同样抽头覆盖范围翻倍（更平滑）
        int width = Mathf.Max(1, bufferSize.x / 2), height = Mathf.Max(1, bufferSize.y / 2);
        buffer.GetTemporaryRT(screenSpaceShadowTexId, width, height, 0, FilterMode.Point,
            RenderTextureFormat.R8, RenderTextureReadWrite.Linear);
        buffer.GetTemporaryRT(screenSpaceShadowTexTempBlurId, width, height, 0, FilterMode.Point,
            RenderTextureFormat.R8, RenderTextureReadWrite.Linear);

        //半影mask + 它的倒手图：1/4分辨率 —— 一个mask纹素对应4×4个屏幕像素（akg/原神的做法）
        //向上取整：整除会把画面最右/最下一列像素丢掉
        int maskWidth = Mathf.Max(1, (bufferSize.x + 3) / 4), maskHeight = Mathf.Max(1, (bufferSize.y + 3) / 4);
        buffer.GetTemporaryRT(screenSpaceShadowMaskTexId, maskWidth, maskHeight, 0, FilterMode.Point,
            RenderTextureFormat.R8, RenderTextureReadWrite.Linear);
        buffer.GetTemporaryRT(screenSpaceShadowMaskTexTempId, maskWidth, maskHeight, 0, FilterMode.Point,
            RenderTextureFormat.R8, RenderTextureReadWrite.Linear);

        //两套纹素尺寸分别上传：mask的blur用mask那套（mask那趟还靠它反推"1个屏幕像素"的uv长度 × 0.25），
        //结果图的双边blur用结果图那套（它读的是半分辨率的结果图，不能被mask的尺寸带偏）
        buffer.SetGlobalVector(screenSpaceShadowTexelSizeId,
            new Vector4(1f / maskWidth, 1f / maskHeight, maskWidth, maskHeight));
        buffer.SetGlobalVector(screenSpaceShadowResultTexelSizeId,
            new Vector4(1f / width, 1f / height, width, height));
    }

    //深度法线prepass：法线（**着色法线**，与延迟 GBuffer2 同口径）写进 _CameraNormalsTexture，
    //深度沿用"主pass要用的同一个深度附件"（用Load，别重复清）。
    //谁需要它：① PCSS（两趟 blur 的法线保边项 + 给"几何法线重构"当翻正参考）；② SSR（接收面反射方向 / 命中点法线）。
    //（阴影 bias 要的**几何法线**不来自这张图：全屏 pass 用 ScreenSpaceGeometricNormal 从深度重构。）
    //⇒ 两台消费者各自调用它（门由调用方出），它自己不掺和任何一方的后续步骤。
    void DrawDepthNormalsPrepass(bool useDynamicBatching, bool useGPUInsancing, int renderingLayerMask)
    {
        //帧调试器分组：和延迟一个套路（命令缓冲区名 + 同名sample）
        buffer.name = "Depth Normals Prepass";
        buffer.BeginSample("Depth Normals Prepass");
        buffer.SetRenderTarget(normalsTextureId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
            depthAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);
        buffer.ClearRenderTarget(false, true, Color.clear);
        //先执行一下：DrawRenderers 是 context 调用、会立刻执行，得让上面的 BeginSample 先生效，它才会落进这个组
        ExecuteBuffer();

        var sortingSettings = new SortingSettings(camera)
        {
            criteria = SortingCriteria.CommonOpaque
        };
        var drawingSettings = new DrawingSettings(depthNormalsShaderTagId, sortingSettings)
        {
            enableDynamicBatching = useDynamicBatching,
            enableInstancing = useGPUInsancing,
            perObjectData = PerObjectData.None//prepass只要有变换/法线，不需要灯光之类的per-object数据
        };
        var filteringSettings = new FilteringSettings(RenderQueueRange.opaque, renderingLayerMask: (uint)renderingLayerMask);
        context.DrawRenderers(cullingResults, ref drawingSettings, ref filteringSettings);
        ExecuteBuffer();
        buffer.EndSample("Depth Normals Prepass");

        //恢复主渲染目标：紧接着不管是画不透明物还是跑PCSS，都要它；
        //Load 保住Setup清好的颜色 + prepass刚写好的深度（不透明物的深度测试还要靠它）
        buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
            depthAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);
        buffer.name = bufferName;//恢复缓冲区名，别影响后面的分组
        ExecuteBuffer();
    }

    //屏幕空间阴影（第3步）：② 把深度拷成可读纹理 ③ 半影mask → 横/竖两趟blur扩宽 → PCSS只在半影带里真算（akg那套）
    //必须在opaque之前调用（opaque的光照要采样这张图），且此时离屏阴影已经画好了。
    //⚠️ 它**不再**负责"深度法线prepass"——那份独立在 DrawDepthNormalsPrepass 里（谁需要谁调用），两者不耦合。
    void DrawScreenSpaceShadow()
    {
        //② 把深度拷成可读纹理：pass0要采样它来重建世界坐标
        //（后面 CopyAttachments 里那段就不会再拷一次了，见那边的注释）
        buffer.name = "Copy Depth";
        buffer.GetTemporaryRT(depthTextureId, bufferSize.x, bufferSize.y, 32, FilterMode.Point, RenderTextureFormat.Depth);
        if (copyTextureSupported)
        {
            buffer.CopyTexture(depthAttachmentId, depthTextureId);
        }
        else
        {
            Draw(depthAttachmentId, depthTextureId, true);
        }
        buffer.SetGlobalTexture(depthTextureId, depthTextureId);
        ExecuteBuffer();

        //③ 四趟（akg那套：先分区，只在半影带里跑PCSS）：半影mask → 横blur → 竖blur → PCSS
        //   帧调试器分组：整个"屏幕空间阴影"一个组
        buffer.name = "Screen Space Shadow";
        buffer.BeginSample("Screen Space Shadow");

        //半影mask：1/4分辨率。本地半影够粗的位置写 0.5（=交给PCSS），否则直接二值(0/1) → _ScreenSpaceShadowMaskTex
        buffer.SetRenderTarget(screenSpaceShadowMaskTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.PenumbraMask, MeshTopology.Triangles, 3);
        buffer.SetGlobalTexture(screenSpaceShadowMaskTexId, screenSpaceShadowMaskTexId);//给下一趟采样

        //横向blur mask（箱式7抽头）：mask → _ScreenSpaceShadowMaskTexTemp
        buffer.SetRenderTarget(screenSpaceShadowMaskTexTempId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.MaskBlurHorizontal, MeshTopology.Triangles, 3);
        buffer.SetGlobalTexture(screenSpaceShadowMaskTexTempId, screenSpaceShadowMaskTexTempId);//给下一趟采样

        //纵向blur mask：_ScreenSpaceShadowMaskTexTemp → mask（转一圈回来，把半影带扩宽）
        buffer.SetRenderTarget(screenSpaceShadowMaskTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.MaskBlurVertical, MeshTopology.Triangles, 3);
        buffer.SetGlobalTexture(screenSpaceShadowMaskTexId, screenSpaceShadowMaskTexId);//给PCSS那趟查"半影带"

        //PCSS：只在半影带里真算（其余像素在shader里直接返回0/1）→ _ScreenSpaceShadowTex
        buffer.SetRenderTarget(screenSpaceShadowTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.PCSS, MeshTopology.Triangles, 3);
        buffer.SetGlobalTexture(screenSpaceShadowTexId, screenSpaceShadowTexId);//给下面两趟blur采样

        //横向blur结果图（双边保边滤波）：_ScreenSpaceShadowTex → _ScreenSpaceShadowTex_TempBlur
        //纵向blur结果图：_ScreenSpaceShadowTex_TempBlur → _ScreenSpaceShadowTex
        //为什么还得有这两趟：PCSS在带子里用的是"每2×2屏幕像素换一个旋转角"的泊松盘，结果图是**带噪**的，
        //而mask那两趟blur只管mask、管不到结果图 ⇒ 结果图仍然需要一次"跨物体边界不糊"的去噪。
        //（想省这两趟的话，得先解决带子里的噪声来源，别直接删）
        buffer.SetRenderTarget(screenSpaceShadowTexTempBlurId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.BlurHorizontal, MeshTopology.Triangles, 3);
        buffer.SetGlobalTexture(screenSpaceShadowTexTempBlurId, screenSpaceShadowTexTempBlurId);//给下一趟采样

        buffer.SetRenderTarget(screenSpaceShadowTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.BlurVertical, MeshTopology.Triangles, 3);

        //恢复主渲染目标（Load：保住Setup里清好的颜色、以及prepass写好的深度），并把结果绑给后面的光照采样
        buffer.SetGlobalTexture(screenSpaceShadowTexId, screenSpaceShadowTexId);
        buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
            depthAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);
        buffer.EndSample("Screen Space Shadow");
        ExecuteBuffer();
        buffer.name = bufferName;//恢复缓冲区名，别影响后面的分组
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
        depthNormalsShaderTagId = new ShaderTagId("DepthNormals");//深度法线prepass（屏幕空间阴影/SSAO用）

    
    
    ///绘制可见几何体
    void DrawVisibleGeometry(bool useDynamicBatching, bool useGPUInsancing, bool useLightsPerObject,
        int renderingLayerMask)
    {
        PerObjectData lightsPerObjectFlags = useLightsPerObject ? PerObjectData.LightData | PerObjectData.LightIndices : PerObjectData.None;//若启用逐对象光照，则传递逐物体的光照信息和光源索引

        //=== 深度法线prepass：屏幕空间阴影和 SSR 都要那张法线图(_CameraNormalsTexture) ===
        //SSR 的追踪要它（背面剔除/反射方向/命中点法线），PCSS 要它（半影带里的几何法线）。
        //两份需求各自进门，函数本身只管"把法线写出来"，不掺和任何一方的后续步骤
        if (useScreenSpaceShadow || useSSR)
        {
            DrawDepthNormalsPrepass(useDynamicBatching, useGPUInsancing, renderingLayerMask);
        }

        //=== 屏幕空间阴影（第3步）：PCSS 那几趟（拷深度 + 半影mask/blur + PCSS）===
        //必须在opaque之前：opaque的光照要采样这张图，而且此时离屏阴影已经画好了
        if (useScreenSpaceShadow)
        {
            DrawScreenSpaceShadow();
        }

        //=== 不透明几何 + 天空盒：单独打一个组 ===
        //（拷贝颜色、SSR、透明物体都在它之后各自开组：它们和它是**平级**的，不并进来）
        buffer.name = "Draw Geometry";
        buffer.BeginSample("Draw Geometry");
        //先执行一下：DrawRenderers 是 context 调用、会立刻执行，得让上面的 BeginSample 先生效，它才会落进这个组
        ExecuteBuffer();

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
        //告诉光照shader：从这之后画的物体都采样屏幕空间阴影图（opaque 和 transparent 都用；关了就是0，走逐像素PCSS）
        buffer.SetGlobalFloat(screenSpaceShadowEnabledId, useScreenSpaceShadow ? 1f : 0f);
        ExecuteBuffer();
        context.DrawRenderers(cullingResults,ref drawingSettings, ref filteringSettings);
        
        //绘制天空盒，原本是context.DrawSkybox(camera);但说已过时
        //下边五行的逻辑很清晰，context创建一个renderList，创建cmd，cmd要画renderlist，context执行cmd，删掉cmd
        // RendererList skyboxRendererList = context.CreateSkyboxRendererList(camera);
        // CommandBuffer cmd = new CommandBuffer { name = "Draw Skybox" };
        // cmd.DrawRendererList(skyboxRendererList);
        // context.ExecuteCommandBuffer(cmd);
        // cmd.Release();
        context.DrawSkybox(camera);//关于它，为什么相机标记为clearFlags为color时看不到天空盒？明明天空盒在默认颜色之后渲染，也不清除天空盒，为啥只能看到颜色？，，，发现clearFlags为color的时候，帧调试器里没有drawSkybox，那就是自动跳过了，大概率是底层C++固定做的判断
        
        //几何那个组到此为止（拷贝和 SSR 都不属于"画几何"，从这往后都是平级的组）
        buffer.EndSample("Draw Geometry");
        ExecuteBuffer();
        buffer.name = bufferName;

        //=== 拷贝颜色/深度（必须放在 SSR 之前：SSR 要采这份"不透明+天空盒"的快照）===
        if (useColorTexture || useDepthTexture)
        {
            CopyAttachments();//内部自带 ExecuteBuffer
        }

        //=== SSR（屏幕空间反射）===
        //必须在本帧"不透明+天空盒"的快照（CopyAttachments：带mip的颜色 + 深度 + 法线）之后、画透明物之前：
        //① 本帧的反射源现在才齐；② 此刻还没画透明物，反射里照不到水面自己。
        //⚠️ 依赖：颜色快照（useColorTexture）和深度/法线得有 —— trace 要读它们。
        //这三趟写出来的是"本帧要写的那张"（下一帧才被不透明物体消费）；画完 _SSRTex 绑的是当帧这张，
        //所以下面画的**透明物**拿到的是当帧的反射（不透明物体拿到的是上一帧那张）
        if (useSSR)
        {
            hiz.Draw(buffer);//先建 HiZ（逐级降采样），追踪那趟要按 mip 采它；此刻深度图已经完整
            ssr.Draw(buffer, colorAttachmentId, depthAttachmentId);//三趟（附件 id 由各渲染器给）
            ExecuteBuffer();//让上面那些 RT/全局绑定立刻生效：紧接着要画透明物了
            buffer.name = bufferName;//恢复缓冲区名（那几趟把它改成了 "Screen Space SSR"）
        }

        //=== 透明物体：自己的组（同样不并进上面那个几何组）===
        //先绘制opaque，再绘制skybox，然后绘制transparent   避免skybox盖住半透物体
        //trans的排序用CommonTransparent，从后往前绘制，和opaque的前往后相反
        //trans咋排序对性能没影响+必须从后往前才有可能正确混合。
        //但如此不能保证正确混合，因为排序是基于对象的位置，针对每个对象排序的。交叉和大的trans物体还是可能错误排序，或许可以把大物体切割成多个小物体来尝试接近，，，能这样干吗？
        buffer.name = "Draw Transparent";
        buffer.BeginSample("Draw Transparent");
        ExecuteBuffer();
        sortingSettings.criteria = SortingCriteria.CommonTransparent;
        drawingSettings.sortingSettings = sortingSettings;
        filteringSettings.renderQueueRange = RenderQueueRange.transparent;
        context.DrawRenderers(cullingResults,ref drawingSettings, ref filteringSettings);

        //屏幕空间阴影图用完了就关掉，别影响后面的相机/后处理（所以这句要在透明物体画完之后）
        buffer.SetGlobalFloat(screenSpaceShadowEnabledId, 0f);
        buffer.EndSample("Draw Transparent");
        ExecuteBuffer();
        buffer.name = bufferName;//恢复缓冲区名，别影响后面的分组
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
            if (useDepthTexture || useScreenSpaceShadow)//屏幕空间阴影也会自己拷一份深度，所以它也要释放
            {
                buffer.ReleaseTemporaryRT(depthTextureId);
            }
        }
        //prepass的法线图是"始终创建"的，所以无条件释放
        buffer.ReleaseTemporaryRT(normalsTextureId);

        //屏幕空间阴影的两对图：只有本帧真的创建过才释放
        if (useScreenSpaceShadow)
        {
            buffer.ReleaseTemporaryRT(screenSpaceShadowTexId);
            buffer.ReleaseTemporaryRT(screenSpaceShadowTexTempBlurId);
            buffer.ReleaseTemporaryRT(screenSpaceShadowMaskTexId);
            buffer.ReleaseTemporaryRT(screenSpaceShadowMaskTexTempId);
        }

        //SSR：本帧的 blur 倒手图已经在 ssr.Draw 里还掉了；两张反射图是**跨帧保留**的
        //（释放走 Setup 的 else 分支，或 ssr.Dispose）
    }

    static bool copyTextureSupported = SystemInfo.copyTextureSupport > CopyTextureSupport.None; 
    
    void CopyAttachments()
    {
        //颜色纹理拷贝（折射/扭曲等透明物体需要）
        //colorMipCount（1 = 不建链）是Render开头算好的字段，函数末尾恢复渲染目标时也要用它
        if (useColorTexture)
        {
            CameraRendererBase.CreateReadableColorTexture(
                buffer, colorTextureId, bufferSize.x, bufferSize.y, useHDR, colorMipCount);
            //写 mip0：两种写法都只写 mip0，mip1..N 靠下面的 GenerateMips 生成。
            //⚠️ 2026-09-16 实测：给"带 mip 的目标"做 blit 写不进内容（帧调试器里那一步是 Blend Zero Zero：
            //   Copy pass 的混合模式来自 [_CameraSrcBlend]/[_CameraDstBlend]，而这两个全局量只在 DrawFinal 里被设过
            //   ⇒ 会话第一次渲染时就写成黑的）。所以开 mip 时也改走 CopyTexture，把目标 mip **显式写成 0**。
            if (copyTextureSupported)
            {
                if (colorMipCount <= 1)
                {
                    buffer.CopyTexture(colorAttachmentId, colorTextureId);
                }
                else
                {
                    buffer.CopyTexture(colorAttachmentId, 0, 0, colorTextureId, 0, 0);
                }
            }
            else
            {
                Draw(colorAttachmentId, colorTextureId);
            }
            if (colorMipCount > 1)
            {
                //mip1..N：上面两种写法都只写了mip0，得自己生成（这就是"多出来的那一趟全屏"）
                buffer.GenerateMips(colorTextureId);
            }
        }
        //深度纹理拷贝（软粒子等需要）
        //注意：屏幕空间阴影那段（prepass之后）已经把深度拷过一次了，不能再拷/再申请同一张临时图
        if (useDepthTexture && !useScreenSpaceShadow)
        {
            buffer.GetTemporaryRT(depthTextureId, bufferSize.x, bufferSize.y, 32, FilterMode.Point, RenderTextureFormat.Depth);
            if (copyTextureSupported)
            {
                buffer.CopyTexture(depthAttachmentId, depthTextureId);
            }
            else
            {
                Draw(depthAttachmentId, depthTextureId, true);
            }
        }
        if (!copyTextureSupported || colorMipCount > 1)
        {
            buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
                depthAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);//Draw/GenerateMips改了渲染目标，统一恢复
        }
        ExecuteBuffer();
    }

    Material material;

    //屏幕空间阴影（第3步）的材质，由 ScreenSpacePCSS.shader 创建
    Material screenSpaceShadowMaterial;

    //ScreenSpacePCSS.shader 里的 pass 顺序（必须和 shader 里 Pass 的先后一致）
    enum ScreenSpaceShadowPass
    {
        PCSS,
        BlurHorizontal,
        BlurVertical,
        //下面三个是"半影mask"那套：它们在 shader 里是追加在**文件末尾**的，
        //所以索引正好接在后面（不要把它们插到上面去，否则前三项的索引会全错位）
        PenumbraMask,
        MaskBlurHorizontal,
        MaskBlurVertical
    }

    Texture2D missingTexture;//因为深度纹理是可选的，所以需要一个缺失的纹理，来避免没有深度纹理时的错误
    
    public CameraRendererForward(Shader shader, Shader screenSpaceShadowShader)
    {
        material = CoreUtils.CreateEngineMaterial(shader);//创建一个材质并隐藏，不会保存为资产
        if (screenSpaceShadowShader)
        {
            screenSpaceShadowMaterial = CoreUtils.CreateEngineMaterial(screenSpaceShadowShader);
        }
        else//没配shader就退化成"不使用屏幕空间阴影"，而不是报错
        {
            Debug.LogWarning("Argonara RP: 管线资产里没有指定 Screen Space Shadow Shader，前向的屏幕空间阴影（PCSS第3步）不可用");
        }
        missingTexture = new Texture2D(1, 1)
        {
            hideFlags = HideFlags.HideAndDontSave, name = "Missing"
        };
        missingTexture.SetPixel(0, 0, Color.white * 0.5f);
        missingTexture.Apply(true, true);
    }

    public override void Dispose()
    {
        ssr.Dispose();//两张持久的反射图（跨帧的，得自己销毁）+ SSR 的材质
        hiz.Dispose();//HiZ 的主图（跨帧常驻的）+ 它的材质
        CoreUtils.Destroy(material);
        CoreUtils.Destroy(screenSpaceShadowMaterial);
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
