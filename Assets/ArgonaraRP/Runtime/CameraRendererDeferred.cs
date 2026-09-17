using UnityEngine;
using UnityEngine.Rendering;

///RenderPipeline需要按顺序处理每个相机，把这个责任转交给此类
///它大致相当于URP的scriptable renderer
//这种方法，让每个相机在未来更容易支持不同的渲染方法，如一个渲染第一人称视图，一个渲染三维地图，或前向和延迟渲染
public partial class CameraRendererDeferred : CameraRendererBase
{
    ScriptableRenderContext context;
    Camera camera;

    //本帧是否走屏幕空间阴影：记录的是"本帧到底有没有创建那两张贴图"，Cleanup() 靠它配对释放。
    //（设置本身不缓存：作为参数传给 Setup()，少一份跨帧状态）
    bool useScreenSpaceShadow;

    //本帧走不走 SSR：由 Setup 里判定（公共部分用 ScreenSpaceReflection.ShouldRender）。
    //建图、_SSRTex 的绑定、那三趟绘制、倒手图释放都在 ScreenSpaceReflection 里（两个渲染器共用一份实现）
    ScreenSpaceReflection ssr = new ScreenSpaceReflection();
    bool useSSR;

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

    //颜色快照要建几级mip（1 = 不建链）。在Render开头算好存这里：
    //拷颜色那两个函数（CopyColorAttachments）拿不到 bufferSettings（它只是Render的参数）和 bufferSize
    int colorMipCount = 1;

    //在我的Deferred流程中，永远先画到colorTexture上，然后再copy到屏幕上
    //private bool useColorTexture;
    
    
    
    ///绘制相机能看到的所有几何图形
    public override void Render(ScriptableRenderContext context, Camera camera, CameraBufferSettings bufferSettings,
        bool useDynamicBatching, bool useGPUInsancing, bool useLightsPerObject,
        ShadowSettings shadowSettings, SSRSettings ssrSettings, PostFXSettings postFXSettings, int colorLUTResolution)
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

        //颜色快照的mip级数（1 = 不建链）：延迟渲染一定会拷颜色，所以这里不用再判断别的条件
        colorMipCount = CameraRendererBase.GetColorMipCount(bufferSettings, bufferSize.x, bufferSize.y);

        //lighting的Setup包含了shadows的render指令，先渲染阴影
        buffer.BeginSample(SampleName);
        buffer.SetGlobalVector(bufferSizeId, new Vector4(1f/bufferSize.x, 1f/bufferSize.y, bufferSize.x, bufferSize.y));//渲染缩放后，替代_ScreenParams
        ExecuteBuffer();
        lighting.Setup(context, camera, cullingResults, shadowSettings, useLightsPerObject,
            cameraSettings.maskLights ? cameraSettings.renderingLayerMask : -1);//相机可选的灯光渲染层过滤
        postFXStack.Setup(context, camera, bufferSize, postFXSettings, useHDR, colorLUTResolution, cameraSettings.finalBlendMode, bufferSettings.bicubicRescaling);
        buffer.EndSample(SampleName);

        //------------------------------2.相机主进程：准备和绘制---------------------------------
        //2.1准备渲染
        Setup(shadowSettings, ssrSettings);
        //2.2渲染
        DrawVisibleGeometry(useDynamicBatching, useGPUInsancing, useLightsPerObject, cameraSettings.renderingLayerMask);
        DrawUnsupportedShaders();

        //------------------------------3.Gizmos、后处理，到屏幕上---------------------------------
        DrawGizmosBeforeFX();//gizmos要区分在后处理前后有不一样
        if (postFXStack.IsActive)
        {
            postFXStack.Render(colorAttachmentId);//若有后处理，用后处理画到屏幕，else再加一个pass画到屏幕
        }
        else
        {
            DrawFinal(cameraSettings.finalBlendMode);//无后处理时，复制颜色附件到CameraTarget，尊重视口和混合模式
            ExecuteBuffer();
        }
        DrawGizmosAfterFX();//这部分gizmos，在后处理后，此时它始终不被物体遮挡，好像是因为没有场景深度了，没法做深度测试

        buffer.EndSample("Setup");
        ExecuteBuffer();
        
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

    
    
    
    
    //用于写入和读取的颜色纹理
    static int colorAttachmentId = Shader.PropertyToID("_CameraColorAttachment");
    static int colorTextureId = Shader.PropertyToID("_CameraColorTexture");
    //用于写入和读取的深度纹理
    static int gDepthId = Shader.PropertyToID("_GBufferDepth");
    static int depthTextureId = Shader.PropertyToID("_CameraDepthTexture");

    //屏幕空间阴影图（第3步：屏幕空间PCSS）：把逐像素的PCSS计算单独写成一张屏幕纹理，供光照Pass一次采样
    static int screenSpaceShadowTexId = Shader.PropertyToID("_ScreenSpaceShadowTex");
    //结果图的blur倒手图：同一张纹理不能在同一次绘制里既读又写，所以横/竖两趟之间来回倒一次（半分辨率）
    static int screenSpaceShadowTexTempBlurId = Shader.PropertyToID("_ScreenSpaceShadowTex_TempBlur");
    //半影mask（akg/原神那套）：1/4分辨率、一个纹素对应4×4个屏幕像素，只标记"阴影/半影/非阴影"三态。
    //有了它，PCSS就只在半影带里跑（其余像素直接返回0或1），mask自己那两趟blur也从"给PCSS去噪"变成"扩宽半影带"
    static int screenSpaceShadowMaskTexId = Shader.PropertyToID("_ScreenSpaceShadowMaskTex");
    //mask自己的blur倒手图：1/4分辨率（和结果图的倒手图不是一套尺寸，不能共用）
    static int screenSpaceShadowMaskTexTempId = Shader.PropertyToID("_ScreenSpaceShadowMaskTexTemp");
    //告诉光照Pass"这一趟要采样屏幕空间阴影图"：只有延迟光照那一趟设1，其余时候是0
    static int screenSpaceShadowEnabledId = Shader.PropertyToID("_ScreenSpaceShadowEnabled");
    //告诉shader"当前是前向还是延迟"（1=延迟、0=前向）：用于区分"用途相同但名字不同"的纹理（法线）
    static int useDeferredRendererId = Shader.PropertyToID("_UseDeferredRenderer");
    //SSR（屏幕空间反射）：反射图的 id、以及 13 个追踪/降噪调参的 id 都在 ScreenSpaceReflection 里（两个渲染器共用同一套名字）。
    //（原先还有个"本帧有没有可用的SSR图"的 uniform，已删：没开SSR时 _SSRTex 绑的是 1×1 纯黑，a=0 自然退回环境反射）

    //【mask那一对】的纹素尺寸（xy = 1/宽、1/高）：mask blur取邻居要用它，mask那趟还靠它反推"1个屏幕像素"
    static int screenSpaceShadowTexelSizeId = Shader.PropertyToID("_ScreenSpaceShadowTexelSize");
    //【结果图那一对】的纹素尺寸：结果图那两趟双边blur取邻居用它（结果图是半分辨率，和mask不是一套尺寸）
    static int screenSpaceShadowResultTexelSizeId = Shader.PropertyToID("_ScreenSpaceShadowResultTexelSize");

    static int[] gBuffersId =
    {
        Shader.PropertyToID("_GBuffer1"), Shader.PropertyToID("_GBuffer2"),
        Shader.PropertyToID("_GBuffer3"), Shader.PropertyToID("_GBuffer4")
    };
    //这里，暂时用它存一下indrect diffuse，毕竟光照计算要用到。我想的是把间接diffuse暂存，间接高光在光照计算算
    //等实现什么实时光照的方法后，弃用这个纹理
    
    static int sourceTextureId = Shader.PropertyToID("_SourceTexture");
    static int srcBlendId = Shader.PropertyToID("_CameraSrcBlend");
    static int dstBlendId = Shader.PropertyToID("_CameraDstBlend");

    private static int bufferSizeId = Shader.PropertyToID("_CameraBufferSize");//因为unity默认提供的_ScreenParams数值不会随我们的渲染缩放调整，需要自己传值替代
    
    
    
    ///将相机的属性应用于上下文context
    void Setup(ShadowSettings shadowSettings, SSRSettings ssrSettings)
    {
        context.SetupCameraProperties(camera); //渲染前设置正确的相机矩阵unity_MatrixVP
        //手动设置 unity_MatrixInvVP（SetupCameraProperties 可能不设它）   GBuffer光照计算需要它来重建世界坐标
        Matrix4x4 view = camera.worldToCameraMatrix;
        Matrix4x4 proj = GL.GetGPUProjectionMatrix(camera.projectionMatrix, true);
        buffer.SetGlobalMatrix(Shader.PropertyToID("unity_MatrixInvVP"), (proj * view).inverse);
        
        CameraClearFlags flags = camera.clearFlags;//它有4个值，1~4是Skybox,Color,Depth,Nothing，

        //这是延迟渲染器
        buffer.SetGlobalInt(useDeferredRendererId, 1);

        AllocateGBuffers();

        AllocateScreenSpaceShadowTextures(shadowSettings);//屏幕空间阴影图（PCSS第3步）

        //本帧走不走 SSR：公共判定（总开关 / Material / 排除反射相机）。
        //延迟这边没有附加条件 —— 它永远有颜色快照（CopyColorAttachments 是无条件跑的）
        useSSR = ScreenSpaceReflection.ShouldRender(ssrSettings, camera);

        //交给 SSR 自己（**每帧都调**，真/假两种走向都在里面）：建(重建)两张持久图 + 绑 _SSRTex(上一帧那张)
        //+ 上传调参；关掉那帧则是释放两张持久图 + 绑 1×1 纯黑（不执行的话本帧会采到上一帧那张不该再用的图）。
        //⚠️ 必须放在下面"设成颜色附件+深度"之前：建图那几帧里会清图、把渲染目标设成 SSR 图。
        ssr.Setup(buffer, ssrSettings, useSSR, bufferSize.x, bufferSize.y, useHDR);

        //用于写入的color缓冲
        buffer.GetTemporaryRT(colorAttachmentId, bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
            useHDR ? RenderTextureFormat.DefaultHDR : RenderTextureFormat.Default);//是否启用HDR只对后处理堆栈有影响，因此在这决定RT的格式
        buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
            gDepthId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);//设置渲染目标的时候，这样写，就是两张纹理共享一个帧缓冲区
        
        buffer.ClearRenderTarget(
            flags <= CameraClearFlags.Depth, //除了清除标识为nothing以外都要清除深度缓冲
            flags <= CameraClearFlags.Color, 
            flags == CameraClearFlags.Color ? camera.backgroundColor.linear : Color.clear);//如果清除标志就是颜色，那么填入相机的清除颜色
        buffer.BeginSample("Setup");
        //用于读取的_CameraColorTexture
        buffer.SetGlobalTexture(colorTextureId, missingTexture);//默认空纹理占位，避免未启用时shader报错
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

    //目前的GBuffer结构
    // GT   格式             R                G               B               A                             总 bit
    // 1    ARGB32 8×4      albedo          albedo          albedo          ShadingModelID(4b)+空(4b)        32
    // 2    ARGB2101010     normal.x        normal.y        normal.z        _ReceiveShadows(1b)+空(1b)       32
    // 3    ARGB32 8×4      roughness       metallic        occlusion       空                               32
    // 4    RGB111110       emission + indirect diffuse                      —                                32
    
    void AllocateGBuffers()
    {
        //声明和创建GBuffer纹理
        buffer.GetTemporaryRT(gDepthId, bufferSize.x, bufferSize.y, 32, FilterMode.Point, 
            RenderTextureFormat.Depth, RenderTextureReadWrite.Linear); //深度图
        buffer.GetTemporaryRT(gBuffersId[0], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
            RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear); //GT1，xyz是颜色，w前4位是ShadingModelID，后四位空
        buffer.GetTemporaryRT(gBuffersId[1], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
            RenderTextureFormat.ARGB2101010, RenderTextureReadWrite.Linear); //GT2，xyz是法线，w前一位是是否_ReceiveShadows，后一位空
        buffer.GetTemporaryRT(gBuffersId[2], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
            RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear); //GT3，xyz是smoothness,metallic,occlusion，w是空
        buffer.GetTemporaryRT(gBuffersId[3], bufferSize.x, bufferSize.y, 0, FilterMode.Bilinear,
            RenderTextureFormat.RGB111110Float, RenderTextureReadWrite.Linear); //GT4，xyz是emission + indirect diffuse and Specular(11，11，10)，没有w通道

    }

    //屏幕空间阴影的**两对**图：结果图（+它的倒手图）按半分辨率；半影mask（+它的倒手图）按1/4分辨率
    //R8单通道就够：目前只有主定向光走PCSS。Point采样：blur是手动取邻居，不需要硬件双线性
    void AllocateScreenSpaceShadowTextures(ShadowSettings shadowSettings)
    {
        //PCSS总开关 或 屏幕空间开关 关掉、或者没配shader → 这几张图都不创建。
        //（必须带上 pcss.enabled：屏幕空间那套只是"实现PCSS的一种方式"，PCSS 关掉时光照Pass走普通PCF、
        //  压根不采这张图 → 不门控就只是白建4张图、白跑5趟）
        useScreenSpaceShadow = shadowSettings.directional.pcss.enabled &&
                               shadowSettings.directional.pcss.screenSpaceBlur && screenSpaceShadowMaterial;
        if (!useScreenSpaceShadow)
        {
            return;
        }

        //结果图 + 它的倒手图：半分辨率。① 像素数变1/4，PCSS那几十次采样和两趟blur都跟着省4倍
        //          ② 同样的抽头数覆盖的世界范围翻倍（等效半径翻倍，顺带更平滑）
        //          ③ 光照Pass采样它时是双线性（采样器本来就是linear_clamp），等于顺便做了上采样
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

    //屏幕空间阴影的四趟（akg那套：先分区，只在半影带里跑PCSS）：
    //  ① 半影mask（1/4分辨率）→ ②③ 横竖两趟箱式blur把半影带扩宽 → ④ PCSS只在带里真算
    //最终 _ScreenSpaceShadowTex 里是"0/1 + 半影带里的PCSS结果"（临时图_TempBlur只是②③之间倒手用）。
    //必须在 CopyDepthAttachments + SetGlobalTexture(GBuffer/深度) 之后调用：① 要读 _CameraDepthTexture 和 _GBuffer2。
    //每趟之间要 SetGlobalTexture：后一趟采样前一趟的结果，靠全局纹理绑定拿到。
    void DrawScreenSpaceShadow()
    {
        //帧调试器是按"命令缓冲区的名字"给每次执行分组的：不在这里改成自己的名字，
        //这几次命令就会挂在上一段的名字（"GBuffer"）下面，看起来像是嵌在GBuffer层级里。
        buffer.name = "Screen Space Shadow";
        buffer.BeginSample("Screen Space Shadow");

        //1.半影mask：1/4分辨率。本地半影够粗的位置写 0.5（=交给PCSS），否则直接二值(0/1) → _ScreenSpaceShadowMaskTex
        //（DontCare：每个像素都会被写满，不需要保留旧内容）
        buffer.SetRenderTarget(screenSpaceShadowMaskTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.PenumbraMask, MeshTopology.Triangles, 3);
        buffer.SetGlobalTexture(screenSpaceShadowMaskTexId, screenSpaceShadowMaskTexId);//给下一趟采样用

        //2.横向blur mask（箱式7抽头）：mask → _ScreenSpaceShadowMaskTexTemp
        buffer.SetRenderTarget(screenSpaceShadowMaskTexTempId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.MaskBlurHorizontal, MeshTopology.Triangles, 3);
        buffer.SetGlobalTexture(screenSpaceShadowMaskTexTempId, screenSpaceShadowMaskTexTempId);//给下一趟采样用

        //3.纵向blur mask：_ScreenSpaceShadowMaskTexTemp → mask（转一圈回来，把半影带扩宽）
        buffer.SetRenderTarget(screenSpaceShadowMaskTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.MaskBlurVertical, MeshTopology.Triangles, 3);
        buffer.SetGlobalTexture(screenSpaceShadowMaskTexId, screenSpaceShadowMaskTexId);//给PCSS那趟查"半影带"

        //4.PCSS：只在半影带里真算（其余像素在shader里直接返回0/1）→ _ScreenSpaceShadowTex
        buffer.SetRenderTarget(screenSpaceShadowTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.PCSS, MeshTopology.Triangles, 3);
        buffer.SetGlobalTexture(screenSpaceShadowTexId, screenSpaceShadowTexId);//给下面两趟blur采样用

        //5.横向blur结果图（双边保边滤波）：_ScreenSpaceShadowTex → _ScreenSpaceShadowTex_TempBlur
        //6.纵向blur结果图：_ScreenSpaceShadowTex_TempBlur → _ScreenSpaceShadowTex
        //为什么还得有这两趟：PCSS在带子里用的是"每2×2屏幕像素换一个旋转角"的泊松盘，结果图是**带噪**的，
        //而mask那两趟blur只管mask、管不到结果图 ⇒ 结果图仍然需要一次"跨物体边界不糊"的去噪。
        //（想省这两趟的话，得先解决带子里的噪声来源，别直接删）
        buffer.SetRenderTarget(screenSpaceShadowTexTempBlurId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.BlurHorizontal, MeshTopology.Triangles, 3);
        buffer.SetGlobalTexture(screenSpaceShadowTexTempBlurId, screenSpaceShadowTexTempBlurId);//给下一趟采样用

        buffer.SetRenderTarget(screenSpaceShadowTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, screenSpaceShadowMaterial,
            (int)ScreenSpaceShadowPass.BlurVertical, MeshTopology.Triangles, 3);

        buffer.EndSample("Screen Space Shadow");
        //设为全局纹理，供后面的光照Pass采样（光照Pass改成采样这张图之前，它只起调试作用）
        buffer.SetGlobalTexture(screenSpaceShadowTexId, screenSpaceShadowTexId);
        ExecuteBuffer();
        buffer.name = bufferName;//恢复本渲染器的缓冲区名，别影响后面命令的分组
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
        
        buffer.SetRenderTarget(new RenderTargetIdentifier[] {gBuffersId[0], gBuffersId[1], gBuffersId[2], gBuffersId[3]}, gDepthId);
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
            new RenderTargetIdentifier[] { gBuffersId[0], gBuffersId[1], gBuffersId[2], gBuffersId[3]},
            gDepthId);
        buffer.ClearRenderTarget(true, true, Color.clear);
        buffer.name = "GBuffer";
        buffer.BeginSample("GBuffer");
        ExecuteBuffer();
        context.DrawRenderers(cullingResults,ref gBufferDrawingSettings, ref filteringSettings);
        ExecuteBuffer();
        
        //将GBuffer传入GPU
        CopyDepthAttachments();//给光照Pass重建posWS     ！用于trans读取的深度纹理是截止到画完GBuffer！
        buffer.SetGlobalTexture(depthTextureId, depthTextureId);
        foreach(var gBufferId in gBuffersId)
            buffer.SetGlobalTexture(gBufferId, gBufferId);

        if(camera.clearFlags >= CameraClearFlags.Color)
            CopyColorAttachments(false); //若相机的ClearFlags为Color，光照计算时候，需要第一次清除的背景色，复制到_CameraColorTexture（这一步只读mip0，不生成mip）

        buffer.EndSample("GBuffer");
        ExecuteBuffer();
        
        //把主光的实时阴影算进屏幕空间阴影图（PCSS第3步；开关打开时才画，帧调试器里会多出"Screen Space Shadow"这一组）
        if (useScreenSpaceShadow)
        {
            DrawScreenSpaceShadow();
        }

        //恢复渲染目标回colorTexture
        buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
            gDepthId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        ExecuteBuffer();

        //为Opaque Lit执行光照计算——全屏三角，读取GBuffer，输出到colorAttachment
        //告诉光照Pass：这一趟直接采样屏幕空间阴影图（不再逐像素算PCSS）
        buffer.SetGlobalFloat(screenSpaceShadowEnabledId, useScreenSpaceShadow ? 1f : 0f);
        buffer.name = "Deferred Lighting";
        buffer.BeginSample("Deferred Lighting");
        buffer.DrawProcedural(Matrix4x4.identity, material, 2, MeshTopology.Triangles, 3);
        buffer.EndSample("Deferred Lighting");
        //用完立刻关掉：后面的天空盒/透明物体、以及其它相机都不该采样这张图
        buffer.SetGlobalFloat(screenSpaceShadowEnabledId, 0f);
        ExecuteBuffer();
        buffer.name = bufferName;
        
        //绘制天空盒
        context.DrawSkybox(camera);//关于它，为什么相机标记为clearFlags为color时看不到天空盒？明明天空盒在默认颜色之后渲染，也不清除天空盒，为啥只能看到颜色？，，，发现clearFlags为color的时候，帧调试器里没有drawSkybox，那就是自动跳过了，大概率是底层C++固定做的判断

        //复制到_CameraColorTexture使其可用(在透明阶段)
        //用于trans读取的颜色纹理内容是截止到画完天空盒
        //这份是"不透明+天空盒"的最终快照，SSR/折射都采它 → 要带mip链（开关开着的话）
        CopyColorAttachments(true);

        //=== SSR（屏幕空间反射）===
        //位置很讲究：① 要采"不透明+天空盒"的颜色快照、_CameraDepthTexture 和 _GBuffer2；
        //② 此刻透明物还没画，水面自己不会被采进反射里。
        //这三趟写出来的是"本帧要写的那张"（下一帧才被不透明物体消费）；画完 _SSRTex 绑的是当帧这张，
        //所以下面画的**透明物**拿到的是当帧的反射（不透明物体在 GBuffer 那趟拿到的是上一帧那张）
        if (useSSR)
        {
            ssr.Draw(buffer, colorAttachmentId, gDepthId);//三趟（附件 id 由各渲染器给）
            ExecuteBuffer();//让上面那些 RT/全局绑定立刻生效：紧接着要画透明物了
            buffer.name = bufferName; //恢复本渲染器的缓冲区名（那几趟改成了 "Screen Space SSR"）
        }

        //画transparent——第2个DrawingSettings，目前有transparnet unlit和lit
        var transparentDrawingSettings = new DrawingSettings(unlitShaderTagId, sortingSettings)
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
        
        //先绘制opaque，再绘制skybox，然后绘制transparent   避免skybox盖住半透物体
        //trans的排序用CommonTransparent，从后往前绘制，和opaque的前往后相反
        //trans咋排序对性能没影响+必须从后往前才有可能正确混合。
        //但如此不能保证正确混合，因为排序是基于对象的位置，针对每个对象排序的。交叉和大的trans物体还是可能错误排序，或许可以把大物体切割成多个小物体来尝试接近，，，能这样干吗？
        sortingSettings.criteria = SortingCriteria.CommonTransparent;
        transparentDrawingSettings.sortingSettings = sortingSettings;
        transparentDrawingSettings.SetShaderPassName(1, litShaderTagId);
        filteringSettings.renderQueueRange = RenderQueueRange.transparent;//就是靠这句判断是不是transparent，对于deferred，opaque lit和opaque clip lit写入GBuffer，transparent lit和其他trans搁这
        context.DrawRenderers(cullingResults,ref transparentDrawingSettings, ref filteringSettings);
    }

    ///用于释放申请的纹理等
    void Cleanup()
    {
        lighting.Cleanup();
        
        //清除用于写入和读取的两张color
        buffer.ReleaseTemporaryRT(colorAttachmentId);
        buffer.ReleaseTemporaryRT(colorTextureId);

        //清除用于写入和读取的两张depth和GBuffer
        buffer.ReleaseTemporaryRT(gDepthId);
        buffer.ReleaseTemporaryRT(depthTextureId);
        for (int i = 0; i < gBuffersId.Length; i++) 
            buffer.ReleaseTemporaryRT(gBuffersId[i]);

        //清除屏幕空间阴影的两对图（只有本帧真的创建过才释放）
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
    
    //画skybox后，创建并拷贝颜色纹理（本帧第二次拷）
    //generateMips：这次拷完要不要顺手把 mip1..N 生成出来。
    //  本帧第一次（光照Pass前的背景色）只读 mip0 → 传false，省一趟全屏；
    //  最后一次（不透明+天空盒的最终快照，SSR/折射采的就是它）→ 传true。
    //注意：两次都要建同样级数的图（同一个id，参数得一样），只是"生不生成"不同
    void CopyColorAttachments(bool generateMips)
    {
        //colorMipCount（1 = 不建链）是Render开头算好的字段，函数末尾恢复渲染目标时也要用它
        CameraRendererBase.CreateReadableColorTexture(
            buffer, colorTextureId, bufferSize.x, bufferSize.y, useHDR, colorMipCount);
        //写 mip0：两种写法都只写 mip0，mip1..N 靠下面的 GenerateMips 生成。
        //⚠️ 2026-09-15 实测：原先给 mip 用的那条"blit 到带 mip 的目标"写不进内容（帧调试器里目标全黑 ⇒ SSR 反射全黑）。
        //   所以开 mip 时也改走 CopyTexture，只是把目标 mip **显式写成 0**（源1级/目标N级这种不匹配，显式指定 mip 更保险）
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

        if (generateMips && colorMipCount > 1)
        {
            //mip1..N：上面两种写法都只写了mip0，得自己生成（这就是"多出来的那一趟全屏"）
            buffer.GenerateMips(colorTextureId);
        }

        if (!copyTextureSupported || colorMipCount > 1)
        {
            buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
                gDepthId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);//Draw/GenerateMips改了渲染目标，统一恢复
        }
        ExecuteBuffer();
    }

    //画GBuffer的Opaque后，创建并拷贝深度纹理    想自己的深度出现在深度纹理上，要开启ZWrite，并且queue在0~2450
    void CopyDepthAttachments()
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
        
        if (!copyTextureSupported)
        {
            buffer.SetRenderTarget(colorAttachmentId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
                gDepthId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store); //Draw改了渲染目标，统一恢复
        }

        ExecuteBuffer();
    }

    Material material;

    //屏幕空间阴影（PCSS第3步）的材质，由 ScreenSpacePCSS.shader 创建
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
    
    public CameraRendererDeferred(Shader shader, Shader screenSpaceShadowShader)
    {
        material = CoreUtils.CreateEngineMaterial(shader);//创建一个材质并隐藏，不会保存为资产
        if (screenSpaceShadowShader)
        {
            screenSpaceShadowMaterial = CoreUtils.CreateEngineMaterial(screenSpaceShadowShader);
        }
        else//没配shader就退化成"不使用屏幕空间阴影"，而不是报错
        {
            Debug.LogWarning("Argonara RP: 管线资产里没有指定 Screen Space Shadow Shader，屏幕空间阴影（PCSS第3步）不可用");
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
