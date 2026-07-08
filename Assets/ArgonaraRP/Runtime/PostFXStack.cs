using UnityEngine;
using UnityEngine.Rendering;
using static PostFXSettings;

//这个stack堆栈，是所有后处理效果的总集，里面可以装载很多个render feature。同时，它是PostFXSettings这个数据类的运行时实例
public partial class PostFXStack
{
    const string bufferName = "Post FX";

    private CommandBuffer buffer = new CommandBuffer { name = bufferName };
    
    ScriptableRenderContext context;

    private Camera camera;
    
    PostFXSettings settings;

    private bool useHDR;

    private int colorLUTResolution;
    
    public bool IsActive => settings != null;//如果没有整体的setting，那么整体的Stack就被跳过

    enum Pass//要调用对应的shader里的第几个pass
    {
        BloomAdd,
        BloomHorizontal,
        BloomPrefilter,
        BloomPrefilterFireflies,
        BloomScatter,
        BloomScatterFinal,
        BloomVertical,
        Copy,
        ColorGradingNone,
        ColorGradingACES,
        ColorGradingNeutral,
        ColorGradingReinhard,
        Final
    }

    ///初始化
    public void Setup(ScriptableRenderContext context, Camera camera, PostFXSettings settings, 
        bool useHDR, int colorLUTResolution)
    {
        this.context = context;
        this.camera = camera;
        this.settings = camera.cameraType <= CameraType.SceneView ? settings : null;//只在特定的相机里渲染，一般就是scene和game，要避免反射探针或材质预览应用上后处理
        this.useHDR = useHDR;
        this.colorLUTResolution = colorLUTResolution;
        ApplySceneViewState();
    }

    private int fxSourceId = Shader.PropertyToID("_PostFXSource"); //就是CameraRenderer里的_CameraFrameBuffer，传过来改了个名字
    private int fxSource2Id = Shader.PropertyToID("_PostFXSource2"); //上采样时每次循环，存储再上一次的完全blur的单次结果，用于和已累加blur再相加
    private int bloomBucibicUpsamplingId = Shader.PropertyToID("_BloomBicubicUpsampling");//是否双三次采样（高质量光晕）
    //降采样时的 9×9 高斯模糊已经把纹理糊得够匀了，so上采样时双线性 vs 双三次区别极小     在明亮物体的 bloom 边缘过渡带，亮度梯度最陡的地方，双线性可能出现轻微块状，才稍微看得出来
    private int bloomPrefilterId = Shader.PropertyToID("_BloomPrefilter");//Bloom最耗时的是第一次全分辨率HV blur，这里直接跳过第一次，得到未blur的1/2分辨率纹理
    private int bloomThresholdId = Shader.PropertyToID("_BloomThreshold");
    private int bloomIntensityId = Shader.PropertyToID("_BloomIntensity");
    private int bloomResultId = Shader.PropertyToID("_BloomResult");
    
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
        if (DoBloom(sourceId))
        {
            DoColorGradingAndToneMapping(bloomResultId);
            buffer.ReleaseTemporaryRT(bloomResultId);
        }
        else
        {
            DoColorGradingAndToneMapping(sourceId);
        }
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
    bool DoBloom(int sourceId)
    {
        BloomSettings bloom = settings.Bloom;
        
        int width = camera.pixelWidth / 2, height = camera.pixelHeight / 2;
        if (bloom.maxIterations == 0 || bloom.intensity <= 0f || height < bloom.downscaleLimit * 2 || width < bloom.downscaleLimit * 2)//这的两个”*2“，是配合跳过第一次半分辨率的，金字塔从1/4分辨率开始，则1/2宽高(这里1/2是上边已经除了2)<limit*2也就是1/4宽高<limit，这宽高是int所以不能除
        {
            return false;
        }

        buffer.BeginSample("Bloom");

        Vector4 threshold;
        threshold.x = Mathf.GammaToLinearSpace(bloom.threshold);
        threshold.y = threshold.x * bloom.thresholdKnee;
        threshold.z = 2f * threshold.y;
        threshold.w = 0.25f / (threshold.y + 0.00001f);
        threshold.y -= threshold.x;
        buffer.SetGlobalVector(bloomThresholdId, threshold);
        
        RenderTextureFormat format = useHDR ? RenderTextureFormat.DefaultHDR : RenderTextureFormat.Default;
        buffer.GetTemporaryRT(bloomPrefilterId, width, height, 0, FilterMode.Bilinear, format);//半分辨率未blur纹理
        Draw(sourceId, bloomPrefilterId, bloom.fadeFireflies ? Pass.BloomPrefilterFireflies : Pass.BloomPrefilter);//第一次，挑出通过threshod的部分，放进第一次的未blur 1/2分辨率图中
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
        //buffer.SetGlobalFloat(bloomIntensityId, 1f);

        Pass combinePass;//上采样时根据additive和scatter模式切换
        Pass finalPass;//对additive，就是bloomAdd   对scatter，额外补充scatter阈值造成的低亮度区域亮度损失
        float finalIntensity;
        if (bloom.mode == BloomSettings.Mode.Additive)
        {
            combinePass = finalPass = Pass.BloomAdd;
            buffer.SetGlobalFloat(bloomIntensityId, 1f);
            finalIntensity = bloom.intensity;
        }
        else
        {
            combinePass = Pass.BloomScatter;
            finalPass = Pass.BloomScatterFinal;
            buffer.SetGlobalFloat(bloomIntensityId, bloom.scatter);
            finalIntensity = Mathf.Min(bloom.intensity, 0.95f);//强度大于 1 不适合用于散射光晕，因为这样会增加光线
        }
        
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
                Draw(fromId, toId, combinePass); //把fromId的纹理和fxSource2Id的纹理，合并到toId上
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

        buffer.SetGlobalFloat(bloomIntensityId, finalIntensity);
        buffer.SetGlobalTexture(fxSource2Id, sourceId);
        buffer.GetTemporaryRT(bloomResultId, camera.pixelWidth, camera.pixelHeight, 0, FilterMode.Bilinear, format);
        Draw(fromId, bloomResultId, finalPass);//bloom结果先渲染到bloomResult RT，供后续tone mapping使用
        buffer.ReleaseTemporaryRT(fromId);
        buffer.EndSample("Bloom");
        return true;
    }

    //原来真是一个脚本做完

    private int colorAdjustmentsId = Shader.PropertyToID("_ColorAdjustments");
    private int colorFilterId = Shader.PropertyToID("_ColorFilter");
    private int whiteBalanceId = Shader.PropertyToID("_WhiteBalance");
    private int splitToningShadowsId = Shader.PropertyToID("_SplitToningShadows");
    private int splitToningHighlightsId = Shader.PropertyToID("_SplitToningHighlights");
    private int channelMixerRedId = Shader.PropertyToID("_ChannelMixerRed");
    private int channelMixerGreenId = Shader.PropertyToID("_ChannelMixerGreen");
    private int channelMixerBlueId = Shader.PropertyToID("_ChannelMixerBlue");
    private int smhShadowsId = Shader.PropertyToID("_SMHShadows");
    private int smhMidtonesId = Shader.PropertyToID("_SMHMidtones");
    private int smhHighlightsId = Shader.PropertyToID("_SMHHighlights");
    private int smhRangeId = Shader.PropertyToID("_SMHRange");
    
    
    void ConfigureColorAdjustments()
    {
        ColorAdjustmentsSettings colorAdjustments = settings.ColorAdjustments;
        buffer.SetGlobalVector(colorAdjustmentsId, new Vector4(
            Mathf.Pow(2f, colorAdjustments.postExposure),
            colorAdjustments.contrast * 0.01f + 1f,
            colorAdjustments.hueShift * (1f / 360f),
            colorAdjustments.saturation * 0.01f + 1f));
        buffer.SetGlobalColor(colorFilterId, colorAdjustments.colorFilter.linear);
    }

    void ConfigureWhiteBalance()
    {
        WhiteBalanceSettings whiteBalance = settings.WhiteBalance;
        buffer.SetGlobalVector(whiteBalanceId, ColorUtils.ColorBalanceToLMSCoeffs(whiteBalance.temperature, whiteBalance.tint));
    }

    void ConfigureSplitToning()
    {
        SplitToningSettings splitToning = settings.SplitToning;
        Color splitColor = splitToning.shadows;
        splitColor.a = splitToning.balance * 0.01f;//把-100~100映射到-1~1，塞进shadows的alpha通道
        buffer.SetGlobalColor(splitToningShadowsId, splitColor);
        buffer.SetGlobalColor(splitToningHighlightsId, splitToning.highlights);
    }

    void ConfigureChannelMixer()
    {
        ChannelMixerSettings channelMixer = settings.ChannelMixer;
        buffer.SetGlobalVector(channelMixerRedId, channelMixer.red);
        buffer.SetGlobalVector(channelMixerGreenId, channelMixer.green);
        buffer.SetGlobalVector(channelMixerBlueId, channelMixer.blue);
    }

    void ConfigureShadowsMidtonesHighlights()
    {
        ShadowsMidtonesHighlightsSettings smh = settings.ShadowsMidtonesHighlights;
        buffer.SetGlobalColor(smhShadowsId, smh.shadows.linear);
        buffer.SetGlobalColor(smhMidtonesId, smh.midtones.linear);
        buffer.SetGlobalColor(smhHighlightsId, smh.highlights.linear);
        buffer.SetGlobalVector(smhRangeId, new Vector4(
            smh.shadowsStart, smh.shadowsEnd, smh.highlightsStart, smh.highLightsEnd));
    }
    
    int colorGradingLUTId = Shader.PropertyToID("_ColorGradingLUT");
    int colorGradingLUTParametersId = Shader.PropertyToID("_ColorGradingLUTParameters");
    int colorGradingLUTInLogC = Shader.PropertyToID("_ColorGradingLUTInLogC");
    
    //色调映射，用于处理HDR颜色，将其转换为LDR颜色     超过1的部分如5的亮度映射到1，暗部几乎不变，是非线性变换
    //一般toneMapping放在Bloom后边
    //这里同时做颜色分级和色调映射        //正确的色彩处理顺序是，原始HDR、色彩矫正、色彩分级、色调映射(tonemapping)、显示器LDR
    void DoColorGradingAndToneMapping(int sourceId)
    {
        ConfigureColorAdjustments();
        ConfigureWhiteBalance();
        ConfigureSplitToning();
        ConfigureChannelMixer();
        ConfigureShadowsMidtonesHighlights();
        
        //准备色彩分级和色调映射的LUT
        int lutHeight = colorLUTResolution;
        int lutWidth = lutHeight * lutHeight;
        buffer.GetTemporaryRT(colorGradingLUTId, lutWidth, lutHeight, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        buffer.SetGlobalVector(colorGradingLUTParametersId, new Vector4(lutHeight, 0.5f / lutWidth, 0.5f / lutHeight, lutHeight / (lutHeight - 1f)));//GetLutStripValue()要求的，写入LUT时的参数
        
        ToneMappingSettings.Mode mode = settings.ToneMapping.mode;
        Pass pass = Pass.ColorGradingNone + (int)mode;
        buffer.SetGlobalFloat(colorGradingLUTInLogC, useHDR && pass != Pass.ColorGradingNone ? 1f : 0f);
        Draw(sourceId, colorGradingLUTId, pass);//色彩分级和色调映射画到LUT查找表     这里实际上不需要任何source，但Draw需要一个原纹理，什么都行，只是填上
        
        buffer.SetGlobalVector(colorGradingLUTParametersId, new Vector4(1f / lutWidth, 1f / lutHeight, lutHeight - 1f));
        Draw(sourceId, BuiltinRenderTextureType.CameraTarget, Pass.Final);
        buffer.ReleaseTemporaryRT(colorGradingLUTId);
    }
    
}
