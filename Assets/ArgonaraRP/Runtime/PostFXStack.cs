using UnityEngine;
using UnityEngine.Rendering;

//这个stack堆栈，是所有后处理效果的总集，里面可以装载很多个render feature。同时，它是PostFXSettings这个数据类的运行时实例
public partial class PostFXStack
{
    const string bufferName = "Post FX";

    private CommandBuffer buffer = new CommandBuffer { name = bufferName };
    
    ScriptableRenderContext context;

    private Camera camera;
    
    PostFXSettings settings;
    
    public bool IsActive => settings != null;//如果没有整体的setting，那么整体的Stack就被跳过

    enum Pass//要调用对应的shader里的第几个pass
    {
        BloomCombine,
        BloomHorizontal,
        BloomPrefilter,
        BloomVertical,
        Copy
    }

    ///初始化
    public void Setup(ScriptableRenderContext context, Camera camera, PostFXSettings settings)
    {
        this.context = context;
        this.camera = camera;
        this.settings = camera.cameraType <= CameraType.SceneView ? settings : null;//只在特定的相机里渲染，一般就是scene和game，要避免反射探针或材质预览应用上后处理
        ApplySceneViewState();
    }

    private int fxSourceId = Shader.PropertyToID("_PostFXSource"); //就是CameraRenderer里的_CameraFrameBuffer，传过来改了个名字
    private int fxSource2Id = Shader.PropertyToID("_PostFXSource2"); //上采样时每次循环，存储再上一次的完全blur的单次结果，用于和已累加blur再相加
    private int bloomBucibicUpsamplingId = Shader.PropertyToID("_BloomBicubicUpsampling");//是否双三次采样（高质量光晕）
    //降采样时的 9×9 高斯模糊已经把纹理糊得够匀了，so上采样时双线性 vs 双三次区别极小     在明亮物体的 bloom 边缘过渡带，亮度梯度最陡的地方，双线性可能出现轻微块状，才稍微看得出来
    private int bloomPrefilterId = Shader.PropertyToID("_BloomPrefilter");//Bloom最耗时的是第一次全分辨率HV blur，这里直接跳过第一次，得到未blur的1/2分辨率纹理
    private int bloomThresholdId = Shader.PropertyToID("_BloomThreshold");
    private int bloomIntensityId = Shader.PropertyToID("_BloomIntensity");
    
    ///
    void Draw(RenderTargetIdentifier from, RenderTargetIdentifier to, Pass pass)
    {
        buffer.SetGlobalTexture(fxSourceId, from);//把from纹理指定到fxSourceId上，，，就是说，之后再用fxSourceId找到的就是这里指定的纹理
        buffer.SetRenderTarget(to, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        //用DrawProcedural绘制三角形，跟defaultVertexShader匹配，比画quad少一半顶点
        buffer.DrawProcedural(Matrix4x4.identity, settings.Material, (int)pass, MeshTopology.Triangles, 3);
    }
    
    ///执行后处理Stack
    public void Render(int sourceId)
    {
        //buffer.Blit(sourceId, BuiltinRenderTextureType.CameraTarget);//Blit是把目标纹理每个像素都重写，不会有上一帧的任何残留，所以不需要ClearRenderTarget
        //Draw(sourceId, BuiltinRenderTextureType.CameraTarget, Pass.Copy);
        DoBloom(sourceId);
        context.ExecuteCommandBuffer(buffer);
        buffer.Clear();
    }
    
    
    //以下，大概是和bloom相关的内容，有些怀疑，是否应该写在这个脚本里，，，，，
    
    //bloom的光晕金字塔层数，每次采样图片大小减半，采样此次的周围像素，多次重复H+V分离模糊
    const int maxBloomPyramidLevels = 16;

    private int bloomPyramidId;//是16个金字塔的纹理的shader属性的id

    public PostFXStack()
    {
        bloomPyramidId = Shader.PropertyToID("_BloomPyramid0");
        for (int i = 1; i < maxBloomPyramidLevels * 2; i++)
        {
            Shader.PropertyToID("_BloomPyramid" + i);
        }
        //↑，因为构造函数是最早一次性连续执行的，每次执行Shader.PropertyToID分配的是连续的内存，因此，这里可以只用一个名称代表16张纹理
    }

    ///一定是（水平、竖直、降采样），这样的循环在做，而不能是一次同时做水平+竖直
    void DoBloom(int sourceId)
    {
        buffer.BeginSample("Bloom");
        PostFXSettings.BloomSettings bloom = settings.Bloom;
        
        int width = camera.pixelWidth / 2, height = camera.pixelHeight / 2;
        if (bloom.maxIterations == 0 || bloom.intensity <= 0f || height < bloom.downscaleLimit * 2 || width < bloom.downscaleLimit * 2)//这的两个”*2“，是配合跳过第一次半分辨率的，金字塔从1/4分辨率开始，则1/2宽高(这里1/2是上边已经除了2)<limit*2也就是1/4宽高<limit，这宽高是int所以不能除
        {
            Draw(sourceId, BuiltinRenderTextureType.CameraTarget, Pass.Copy);//完全跳过bloom的情况
            buffer.EndSample("Bloom");
            return;
        }

        Vector4 threshold;
        threshold.x = Mathf.GammaToLinearSpace(bloom.threshold);
        threshold.y = threshold.x * bloom.thresholdKnee;
        threshold.z = 2f * threshold.y;
        threshold.w = 0.25f / (threshold.y + 0.00001f);
        threshold.y -= threshold.x;
        buffer.SetGlobalVector(bloomThresholdId, threshold);
        
        RenderTextureFormat format = RenderTextureFormat.Default;
        buffer.GetTemporaryRT(bloomPrefilterId, width, height, 0, FilterMode.Bilinear, format);//半分辨率未blur纹理
        Draw(sourceId, bloomPrefilterId, Pass.BloomPrefilter);//第一次，挑出通过threshod的部分，放进第一次的未blur 1/2分辨率图中
        width /= 2;//之后，从1/4分辨率开始Bloom
        height /= 2;
        
        int fromId = bloomPrefilterId, toId = bloomPyramidId + 1;//第一层的midId刚好是bloomPyramidId，因此toId第一个得+1      半分辨率作为开头

        //降采样
        int i;
        for (i = 0; i < bloom.maxIterations; i++)
        {
            if (height < bloom.downscaleLimit || width < bloom.downscaleLimit)
            {
                break;
            }

            int midId = toId - 1;
            buffer.GetTemporaryRT(midId, width, height, 0, FilterMode.Bilinear, format);//若图片还有合适的大小，继续生成更小的pyramid
            buffer.GetTemporaryRT(toId, width, height, 0, FilterMode.Bilinear, format);//若图片还有合适的大小，继续生成更小的pyramid
            Draw(fromId, midId, Pass.BloomHorizontal);//做1*9水平模糊
            Draw(midId, toId, Pass.BloomVertical);//把水平模糊后的结果，每个像素带有水平9个像素信息的，做竖直模糊
            fromId = toId;
            toId += 2;
            width /= 2;
            height /= 2;
        }
        //↑，有三张纹理，from（来自cameraRenderer的临时绘制目标frameBufferId），mid和to（刚get的temporaryRT）
        //最开始的时候，from的id是frameBufferId，随便是多少。mid是pyramid（就是0），to是pyramid1
        //继续循环，from变成pyramid1，让from指向上次刚模糊过的。mid是pyramid2，to是pyramid3...    再下from是3，mid是4，to是5...
        //下采样最后，fromId指向的是分辨率最低的，经过n次Horizontal和Vertical模糊的纹理
        //说是金字塔，第一次循环是1/2分辨率，之后变成1/2的n次方分辨率越来越小，实际是倒着的金字塔

        buffer.ReleaseTemporaryRT(bloomPrefilterId);//上采样前，已不需要1/2分辨率临时纹理
        buffer.SetGlobalFloat(bloomBucibicUpsamplingId, bloom.bicubicUpsampling ? 1f : 0f);
        buffer.SetGlobalFloat(bloomIntensityId, 1f);
        
        if (i > 1)
        {
            //假如一共走4轮，最后一次for循环，from，mid，to是5,6,7，经过赋值from和to+=2，三者变成了7,6（它不再用了）,9
            buffer.ReleaseTemporaryRT(fromId - 1);
            toId -= 5;
            //释放最后一轮的mid(也就是6，上采样用不到)，并将to设置为低一级的水平模糊的纹理，存了啥不重要，会被两次完整blur的累加结果覆盖    to-=5，是先-=2回到正常的to(最模糊ver)，再-=3，到了from的7的前一轮再前半轮的水平模糊中间纹理=4
            //此时from是第4轮的7(1/16，最模糊ver)     to是第3轮的4（水平模糊中间纹理）  此时他俩差3

            //上采样，进入前i=4，i -= 1变成3，执行3次循环
            for (i -= 1; i > 0; i--)
            {
                buffer.SetGlobalTexture(fxSource2Id, toId + 1);
                Draw(fromId, toId, Pass.BloomCombine); //把fromId的纹理和fxSource2Id的纹理，合并到toId上
                buffer.ReleaseTemporaryRT(fromId);
                buffer.ReleaseTemporaryRT(toId + 1);
                fromId = toId;
                toId -= 2;
            }
            //反向的，从分辨率最小时候依次往分辨率大的加
            //↑，三张纹理，开始的时候，from是7，fxSource2Id是5，to是4
            //i=3，把7（第4轮最模糊）和5（第3轮最模糊）合并重绘到4（是中间水平模糊但已覆盖）上，   ！from，to此时距离3！，6没用到已经释放了，就这一次是特殊处理
            //i=2，把4（第34轮最模糊累加）和3（第2轮最模糊）合并到2（是中间水平模糊但已覆盖）上，  ！from，to此时相距2！！！  以后都是
            //i=1，把2（第234轮最模糊累加）和1（第1轮最模糊）合并到0（是中间水平模糊但已覆盖）上，  距离2
            //就只有三次循环，，，此时pyramid0的Id的纹理存储着所有轮半分辨率模糊的累加值
        }
        else
        {
            buffer.ReleaseTemporaryRT(bloomPyramidId);//如果只有1次或0次bloom迭代，就跳过上采样
        }

        buffer.SetGlobalFloat(bloomIntensityId, bloom.intensity);//只有最后传到相机时，用自己设定的intensity，其余时候都是1
        buffer.SetGlobalTexture(fxSource2Id, sourceId);
        Draw(fromId, BuiltinRenderTextureType.CameraTarget, Pass.BloomCombine);//此时sourceId是fxSource2Id是原本未处理的图，formId是fxSourceId是完全bloom的图，加和到屏幕上
        buffer.ReleaseTemporaryRT(fromId);
        buffer.EndSample("Bloom");
    }
    
    
    
}
