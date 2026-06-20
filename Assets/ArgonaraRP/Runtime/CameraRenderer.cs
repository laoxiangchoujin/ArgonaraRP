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
    
    ///绘制相机能看到的所有几何图形
    public void Render(ScriptableRenderContext context, Camera camera, bool useDynamicBatching,
        bool useGPUInsancing, bool useLightsPerObject, ShadowSettings shadowSettings)
    {
        this.context = context;
        this.camera = camera;

        PrepareBuffer();
        PrepareForSceneWindow();//给scene view里的UI物体添加到世界几何体中，因为可能会为场景增加一些几何体，所以要在剔除前做
        if (!Cull(shadowSettings.maxDistance))
        {
            return;
        }
        
        //如果给lighting一个专门的sample，可以在主相机claer之前，把阴影项嵌套在main camera中
        buffer.BeginSample(SampleName);
        ExecuteBuffer();
        lighting.Setup(context, cullingResults, shadowSettings, useLightsPerObject);//在绘制可见物体前，先设置场景照明，传入相机的裁剪结果（可见范围）
        buffer.EndSample(SampleName);
        
        Setup();//lighting的Setup包含了shadows的render指令，先渲染阴影，然后在此做相机的主进程
        DrawVisibleGeometry(useDynamicBatching, useGPUInsancing, useLightsPerObject);
        DrawUnsupportedShaders();
        DrawGizmos();
        lighting.Cleanup();//在提交之前，清空shadowmap
        Submit();
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
    
    ///将相机的属性应用于上下文context
    void Setup()
    {
        context.SetupCameraProperties(camera); //渲染前设置正确的相机矩阵unity_MatrixVP
        CameraClearFlags flags = camera.clearFlags;//它有4个值，1~4是Skybox,Color,Depth,Nothing，
        buffer.ClearRenderTarget(
            flags < CameraClearFlags.Nothing, //除了清除标识为nothing以外都要清除深度缓冲
            flags <= CameraClearFlags.Color, 
            flags == CameraClearFlags.Color ? camera.backgroundColor.linear : Color.clear);//如果清除标志就是颜色，那么填入相机的清除颜色
        buffer.BeginSample(SampleName);
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
    void DrawVisibleGeometry(bool useDynamicBatching, bool useGPUInsancing, bool useLightsPerObject)
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
            perObjectData = PerObjectData.ReflectionProbes |//每个对象都要有反射探针
                            PerObjectData.Lightmaps | //用于把物体的lightmapUV传给shader
                            PerObjectData.ShadowMask |
                            PerObjectData.LightProbe | 
                            PerObjectData.OcclusionProbe |
                            PerObjectData.LightProbeProxyVolume |
                            PerObjectData.OcclusionProbeProxyVolume |
                            lightsPerObjectFlags//若启用了逐对象的灯光，GPU 实例化的效率会降低，因为不同物体若灯光不同，容易造成UnityPerDraw CBUFFER 的unity_LightData或unity_LightIndices不同，不能一次实例化，增加drawcall。SRP 合批不受影响
        };
        drawingSettings.SetShaderPassName(1, litShaderTagId);//启用这个tag的shader，名字确实奇怪，它是维护一个ShaderTagId的表，0是创建时候的tag，unity按照顺序去找匹配的pass
        var filteringSettings = new FilteringSettings(RenderQueueRange.opaque);//指出哪些render队列是允许的，，，这个是说渲染的quene吗，就是1000，2000那种？
        context.DrawRenderers(cullingResults,ref drawingSettings, ref filteringSettings);
        
        //绘制天空盒，原本是context.DrawSkybox(camera);但说已过时
        //下边五行的逻辑很清晰，context创建一个renderList，创建cmd，cmd要画renderlist，context执行cmd，删掉cmd
        // RendererList skyboxRendererList = context.CreateSkyboxRendererList(camera);
        // CommandBuffer cmd = new CommandBuffer { name = "Draw Skybox" };
        // cmd.DrawRendererList(skyboxRendererList);
        // context.ExecuteCommandBuffer(cmd);
        // cmd.Release();
        context.DrawSkybox(camera);//关于它，为什么相机标记为clearFlags为color时看不到天空盒？明明天空盒在默认颜色之后渲染，也不清除天空盒，为啥只能看到颜色？，，，发现clearFlags为color的时候，帧调试器里没有drawSkybox，那就是自动跳过了，大概率是底层C++固定做的判断
        
        //先绘制opaque，再绘制skybox，然后绘制transparent   避免skybox盖住半透物体
        //trans的排序用CommonTransparent，从后往前绘制，和opaque的前往后相反
        //trans咋排序对性能没影响+必须从后往前才有可能正确混合。
        //但如此不能保证正确混合，因为排序是基于对象的位置，针对每个对象排序的。交叉和大的trans物体还是可能错误排序，或许可以把大物体切割成多个小物体来尝试接近，，，能这样干吗？
        sortingSettings.criteria = SortingCriteria.CommonTransparent;
        drawingSettings.sortingSettings = sortingSettings;
        filteringSettings.renderQueueRange = RenderQueueRange.transparent;
        context.DrawRenderers(cullingResults,ref drawingSettings, ref filteringSettings);
    }

    
}
