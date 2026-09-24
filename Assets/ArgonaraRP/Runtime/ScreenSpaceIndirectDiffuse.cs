using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

//屏幕空间间接光（SSGI）：半球随机方向 → Hi-Z 追踪找命中 → 命中点用（albedo × 主光）着色、
//没命中的靠可信度退回烘焙 → 时间累积 → 双边滤波。产出一张**半分辨率 GI 图**，被物体着色读去当间接漫反射。
//和 SSR 一样**晚一帧**（物体着色时拿不到本帧结果）⇒ GI 图必须跨帧持久 + 双缓冲。
//⚠️ 状态是**每个相机一份**（和 TAA 同一套）：同一个渲染器实例会被多台相机**轮流**调用（Game 视图 + Scene 视图），
//   共用一份历史的话它们会互相把对方刚画的那帧当成"上一帧"（再叠加"这帧没跑就释放"⇒ 每帧白重建）。
public class ScreenSpaceIndirectDiffuse
{
    //=============== 一台相机的全部跨帧状态 ===============
    sealed class CameraState
    {
        //两张跨帧持久的 GI 图（双缓冲）：本帧读 [readIndex]、写另一张
        public RenderTexture[] giTextures = new RenderTexture[2];
        public int readIndex;
        public int width, height;//上次按什么尺寸建的（变了才重建）
        public bool fullResolution;//上次是按半分辨率还是全分辨率建的（切换也要重建）

        //时间累积（没运动矢量，靠深度 + 上一帧 VP 重投影）
        public Matrix4x4 currentViewProjection;
        public Matrix4x4 previousViewProjection;
        public bool hasHistory;//历史里真的存过东西（没存过 ⇒ 这帧必须重置）
        public bool resetHistory = true;//这帧不混合历史

        //每帧的随机种子：射线方向**必须一帧一变**，否则时间累积永远看不到新方向（每台相机各自推进）
        public int randomSampleIndex;
        public Vector2 randomOffset;

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

    //Halton 上取多少帧一个循环
    const int randomSampleCount = 64;
    //某台相机连续多少帧没渲染就算"不用了"，回收它的两张 GI 图（约 1 秒；见 GetState 里的说明）
    const int stateKeepFrames = 60;

    Material material;//本帧要画的材质（Setup 从 settings 拿；Dispose 销毁）
    List<Entry> entries = new List<Entry>();

    //=========================== Shader 里用的名字 ===========================
    //⚠️ 必须和 ScreenSpaceIndirectDiffuse.shader 里声明的一致（改名字要三处一起改：C# / shader / 绑定处）
    static int
        //---- 纹理 ----
        ssgiTexId = Shader.PropertyToID("_SSGITex"),        //持久的"read 那张"：物体着色读它，也是时间累积的历史
        traceTexId = Shader.PropertyToID("_SSGITraceTex"),  //本帧追踪结果（半分辨率临时图 A）
        tempTexId = Shader.PropertyToID("_SSGITempTex"),    //时间累积/双边倒手（半分辨率临时图 B）
        sourceTexId = Shader.PropertyToID("_SSGISourceTex"),//滤波每趟的"当前输入"（横竖之间靠它倒手）
        texelSizeId = Shader.PropertyToID("_SSGITexelSize"),//(1/宽, 1/高, 宽, 高)
        blueNoiseId = Shader.PropertyToID("_SSGIBlueNoise"),//STBN 时空蓝噪声图集（没配就绑白图 + 开关 0）
        blueNoiseEnabledId = Shader.PropertyToID("_SSGIBlueNoiseEnabled"),
        sliceIndexId = Shader.PropertyToID("_SSGISliceIndex"),//本帧用图集里的第几片（0..63）
        //---- 矩阵 ----
        prevViewProjId = Shader.PropertyToID("_SSGIPrevViewProj"),//上一帧 VP（未抖动）：没 MV，重投影靠它
        //---- 参数（对应 ScreenSpaceIndirectDiffuseSettings 的字段）----
        rayCountId = Shader.PropertyToID("_SSGIRayCount"),
        rayLengthId = Shader.PropertyToID("_SSGIRayLength"),
        stepCountLimitId = Shader.PropertyToID("_SSGIStepCountLimit"),
        thicknessId = Shader.PropertyToID("_SSGIThickness"),
        screenFadeId = Shader.PropertyToID("_SSGIScreenFade"),
        intensityId = Shader.PropertyToID("_SSGIIntensity"),
        temporalWeightId = Shader.PropertyToID("_SSGITemporalWeight"),
        temporalScaleId = Shader.PropertyToID("_SSGITemporalScale"),
        motionBlendScaleId = Shader.PropertyToID("_SSGIMotionBlendScale"),//重投影位移的放大系数（没 MV 时的代偿）
        blurRadiusId = Shader.PropertyToID("_SSGIBlurRadius"),
        debugIndirectId = Shader.PropertyToID("_SSGIDebugIndirect"),
        otherLightLimitId = Shader.PropertyToID("_SSGIOtherLightLimit"),//命中点参与着色的其他光源（点光/聚光）上限
        randomOffsetId = Shader.PropertyToID("_SSGIRandomOffset"),//xy = 随机种子，z = 这帧丢掉历史
        jitterId = Shader.PropertyToID("_SSGIJitter");//xy = 本帧 TAA 抖动（UV 单位）：重投影出来的历史 UV 要加回去

    //shader 里的 pass 顺序（**必须和 shader 里 Pass 的先后完全一致**）
    private enum Pass
    {
        Trace,    //0：半球追踪 → 本帧 GI（临时图 A）
        Temporal, //1：时间累积（读历史 + A → 临时图 B）
        BlurX,    //2：横向双边（读上一步 → 写另一张）
        BlurY,    //3：纵向双边（读上一步 → 写持久图里本帧该写的那张）
    }

    //=========================== 判定 / 状态查找 ===========================

    ///本帧走不走 SSGI 的公共判定（总开关 + 配了 shader + 相机类型合适）
    public static bool ShouldRender (ScreenSpaceIndirectDiffuseSettings settings, Camera camera)
    {
        return settings != null && settings.enabled && settings.Material != null && IsEligible(camera);
    }

    ///哪些相机**不跑** SSGI（也**不许碰状态**）：
    ///  · 反射相机：一台相机要出 cubemap 六个面 ⇒ 六面会互相把对方当成"上一帧"；
    ///  · 预览相机：编辑器里临时渲染（材质预览、缩略图等），别为它一直占两张半屏图。
    ///其余（Game 视图、Scene 视图、以后的多相机）各自有各自的状态 ⇒ 互不干扰。
    static bool IsEligible (Camera camera)
    {
        return camera != null &&
               camera.cameraType != CameraType.Reflection &&
               camera.cameraType != CameraType.Preview;
    }

    ///给**没接 SSGI 的渲染器**（前向）用的兜底：每帧把 `_SSGITex` 绑成 1×1 纯黑。
    ///物体着色（GetGI）是两条路共用的、会采这张图，a = 0 ⇒ 逐像素退回烘焙/探针。
    ///（和 SSR 的"没开就绑黑图"一个套路，所以不需要任何开关 uniform）
    public static void BindFallback (CommandBuffer buffer)
    {
        buffer.SetGlobalTexture(ssgiTexId, Texture2D.blackTexture);
    }

    ///拿这台相机的状态；没有就新建（新建的 state 里 resetHistory 初值就是 true ⇒ 天然是"首帧要重置"）。
    ///顺手回收两种"不再需要"的条目：**相机被销毁**的、以及**很久没渲染**的（Scene 视图窗口关掉、一次性相机等）。
    ///⚠️ 宽限期取 1 秒左右而不是 1 帧：Scene 视图/Game 视图偶尔跳帧（编辑器按需重绘）不能算"不用了"。
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

    ///每帧都调（真/假两种走向都在里面）：建(重建)这两台相机（每台一份）的 GI 图 + 绑 _SSGITex(上一帧那张) + 上传参数。
    ///⚠️ 必须放在渲染器"设成颜色附件 + 深度"之前（建图那几帧会清图、把渲染目标设成 GI 图）。
    ///viewProjection：本帧的 VP（**未抖动**，没运动矢量，时间累积靠它 + 深度重投影）。
    ///jitter：本帧 TAA 的抖动（UV 单位）。既然 VP 是**没抖**的，投出来的历史 UV 天然偏了 −j ⇒ Temporal 那趟要加回去
    ///（TAA 里那行的同款做法；TAA 没开时传 0，加了等于没加）。
    public void Setup (CommandBuffer buffer, ScreenSpaceIndirectDiffuseSettings settings, bool use,
        Camera camera, int screenWidth, int screenHeight, Matrix4x4 viewProjection, Vector2 jitter)
    {
        if (!IsEligible(camera))
        {
            //被排除的相机（反射/预览）：状态一个都不碰，但**全局绑定要刷** —— 不刷的话它们会沿用
            //上一台相机留下的 GI 图（串画面）。绑黑图 ⇒ a = 0 ⇒ 物体着色逐像素退回烘焙
            buffer.SetGlobalTexture(ssgiTexId, Texture2D.blackTexture);
            return;
        }

        if (!use || settings == null || settings.Material == null)
        {
            //真的关掉（总开关关 / 没配 shader）⇒ **所有相机**的 GI 图都放了，重新开起来时重建
            material = null;//让 Draw 早退
            ReleaseAllStates();
            buffer.SetGlobalTexture(ssgiTexId, Texture2D.blackTexture);
            return;
        }

        material = settings.Material;//本帧要画的材质（Draw 用它画那四趟，Dispose 负责销毁）

        CameraState state = GetState(camera);
        AllocateTextures(buffer, state, screenWidth, screenHeight, settings.fullResolution);

        //绑成"读"的那张 = **上一帧**滤波后的最终结果：本帧物体着色采它（rgb = 辐照度、a = 可信度），
        //Temporal 那趟也拿它当历史。
        buffer.SetGlobalTexture(ssgiTexId, state.giTextures[state.readIndex]);

        state.currentViewProjection = viewProjection;
        if (NeedResetHistory(state, viewProjection))
        {
            state.resetHistory = true;
        }

        //本帧的随机种子（Halton 64 帧循环）：每台相机各自推进，互不干扰
        state.randomSampleIndex = (state.randomSampleIndex + 1) % randomSampleCount;
        state.randomOffset = new Vector2(Halton(state.randomSampleIndex + 1, 2), Halton(state.randomSampleIndex + 1, 3));

        SetParameters(buffer, state, settings, jitter);
    }

    ///本帧四趟（Trace → Temporal → BlurX → BlurY），结果落在"这台相机持久图里本帧该写的那张"；
    ///两张临时图（_SSGITraceTex / _SSGITempTex）在 Setup 里借、Cleanup 里还，这里只是用。
    ///⚠️ 得传 camera：状态是每个相机一份（同一个渲染器实例被多台相机轮流用）。
    ///colorAttachment / depthAttachment：调用方自己的附件 id（延迟那边是颜色附件 + _GBufferDepth）。
    ///⚠️ 结尾必须把渲染目标**恢复**成调用方的颜色/深度附件：这四趟把它改到了 GI 图/临时图上，
    ///   而调用方紧接着要画透明物 ⇒ 不恢复就会画进 GI 图里（SSR 关着、只开 SSGI 时必踩）。
    ///⚠️ 这里把 buffer.name 改成 "Screen Space SSGI"（帧调试器分组）⇒ 调用方画完自己恢复。
    public void Draw (CommandBuffer buffer, Camera camera, RenderTargetIdentifier colorAttachment,
        RenderTargetIdentifier depthAttachment)
    {
        CameraState state = FindState(camera);
        if (material == null || state == null || state.giTextures[0] == null)//Setup 里已经挡过一道，这里再兜一层
        {
            return;
        }

        //本帧写这张；另一张（readIndex 那张）是"上一帧的结果"，Setup 里已经绑给 _SSGITex 了
        RenderTexture writeTexture = state.giTextures[1 - state.readIndex];

        buffer.name = "Screen Space SSGI";
        buffer.BeginSample("Screen Space SSGI");

        //1.追踪（半分辨率）→ _SSGITraceTex。这一趟不采 _SSGITex：追踪要的是"本帧裸结果"，历史只给下一趟用
        buffer.SetRenderTarget(traceTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, material, (int)Pass.Trace, MeshTopology.Triangles, 3);

        //2.时间累积：本帧追踪（_SSGISourceTex）+ 历史（_SSGITex，此时还指着"读"的那张）→ _SSGITempTex
        //⚠️ 这一趟之前**不能**把 _SSGITex 改绑成 writeTexture —— Temporal 就是靠它拿历史的
        //   （SSR 是 Trace 一开头就把 _SSRTex 改绑成新图的，我们这里不能照抄）
        buffer.SetGlobalTexture(sourceTexId, traceTexId);
        buffer.SetRenderTarget(tempTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, material, (int)Pass.Temporal, MeshTopology.Triangles, 3);

        //3.横向双边：_SSGITempTex → _SSGITraceTex（两张临时图来回倒手，省下第三张）
        buffer.SetGlobalTexture(sourceTexId, tempTexId);
        buffer.SetRenderTarget(traceTexId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, material, (int)Pass.BlurX, MeshTopology.Triangles, 3);

        //4.纵向双边：_SSGITraceTex → **持久图里本帧该写的那张**（直接写过去，省一次拷回）
        buffer.SetGlobalTexture(sourceTexId, traceTexId);
        buffer.SetRenderTarget(writeTexture, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
        buffer.DrawProcedural(Matrix4x4.identity, material, (int)Pass.BlurY, MeshTopology.Triangles, 3);

        //5.把 _SSGITex 指到本帧这张：下一帧 Setup 会按交换后的索引再绑一次，这句主要图个"画完 GI 图就是当帧结果"
        //   （调试时看着一致；顺带让后面采 _SSGITex 的东西拿到当帧的）
        buffer.SetGlobalTexture(ssgiTexId, writeTexture);

        //6.恢复调用方的渲染目标（紧接着画透明物，它们要的是颜色附件 + 深度附件）
        buffer.SetRenderTarget(colorAttachment, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
            depthAttachment, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);

        buffer.EndSample("Screen Space SSGI");
    }

    ///每帧末尾调（**在 Draw 之后**）：换双缓冲索引 + 把本帧 VP 存成"上一帧 VP" + 清 resetHistory + 还两张中间图。
    ///⚠️ 得传 camera（状态每台一份）；顺序讲究：Setup 里上传的 `_SSGIPrevViewProj` 必须是**上一帧**那份 VP。
    public void Cleanup (CommandBuffer buffer, Camera camera)
    {
        CameraState state = FindState(camera);
        if (state == null)//这帧没走 Setup（被相机类型挡了 / 关掉了）⇒ 那张临时图也不是我们借的
        {
            return;
        }

        //本帧写的那张 = 下一帧的"上一帧结果"（下一帧 Setup 会按新索引把它绑成 _SSGITex）
        //⚠️ 交换只能在这做：AllocateTextures 里不能重置索引，否则双缓冲永远不交换
        state.readIndex = 1 - state.readIndex;
        //本帧 VP → 上一帧 VP（下一帧 Setup 上传它，Temporal 拿它重投影）
        state.previousViewProjection = state.currentViewProjection;
        state.hasHistory = true;
        //这一帧的"重置"标记用完就清（下次由"刚重建 / 瞬移 / 切场景"再置）
        state.resetHistory = false;

        //两张中间图是 Setup 借的临时图（_SSGITraceTex / _SSGITempTex），本帧那四趟画完就没用了
        buffer.ReleaseTemporaryRT(traceTexId);
        buffer.ReleaseTemporaryRT(tempTexId);
    }

    ///给外部用的"强制丢历史"（切场景：相机没动但画面全换了，靠瞬移判定抓不到）：
    ///**所有相机**下一帧只写当前帧、不混合历史。标记由 Cleanup 清掉。
    public void RequestResetHistory ()
    {
        for (int i = 0; i < entries.Count; i++)
        {
            entries[i].state.resetHistory = true;
        }
    }

    ///释放这个类持有的东西（渲染器 Dispose 时调）：所有相机的持久 GI 图 + 那份材质。
    public void Dispose ()
    {
        ReleaseAllStates();
        //材质是 `ScreenSpaceIndirectDiffuseSettings` 惰性创建的那一份（两边引用同一个）：
        //销毁后设置里那个字段变成"假 null"，下次取 Material 会自己重建 ⇒ 这里销毁是安全的
        CoreUtils.Destroy(material);
        material = null;
    }

    //=========================== 内部工具 ===========================

    ///按屏幕尺寸建（或重建）**这台相机**的两张双缓冲 GI 图 + 本帧的两张中间图。
    ///fullResolution：设置里的开关（关 = 半分辨率，省 4 倍像素；全分辨率 = 细节上限翻倍、显存/带宽 ×4）。
    ///⚠️ 会把新建的图顺手清一次（新图内容未定义，不清的话第一帧/重建帧会把垃圾当"上一帧的结果"），
    ///   清完渲染目标停在最后清的那张图上 ⇒ 调用方紧接着要画东西的话，自己 SetRenderTarget 恢复。
    void AllocateTextures (CommandBuffer buffer, CameraState state, int screenWidth, int screenHeight, bool fullResolution)
    {
        //半分辨率：GI 是低频结果，像素数省 4 倍（时间累积和两趟双边都在这个尺寸上做）
        int width = Mathf.Max(1, fullResolution ? screenWidth : screenWidth / 2);
        int height = Mathf.Max(1, fullResolution ? screenHeight : screenHeight / 2);

        //⚠️ 判断"要不要重建"**不能**拿 rt.format 去比：请求的格式和平台解析后的具体格式可能不相等 ⇒ 每帧都判定"变了"
        bool needRebuild = state.giTextures[0] == null || state.width != width || state.height != height ||
                           state.fullResolution != fullResolution;
        if (needRebuild)
        {
            ReleaseState(state);//两张一起换，保证双缓冲从同一起点开始
            state.width = width;
            state.height = height;
            state.fullResolution = fullResolution;
            state.readIndex = 0;
            state.resetHistory = true;//刚重建 ⇒ 这帧不混历史
            state.previousViewProjection = Matrix4x4.identity;//别拿旧的 VP 去重投影
            state.hasHistory = false;

            for (int i = 0; i < state.giTextures.Length; i++)
            {
                //ARGBHalf：存的是颜色（间接光会超过 1）+ alpha 有含义（可信度）
                state.giTextures[i] = new RenderTexture(width, height, 0, RenderTextureFormat.ARGBHalf,
                    RenderTextureReadWrite.Linear)
                {
                    name = "_SSGITex" + i,
                    hideFlags = HideFlags.HideAndDontSave,
                    filterMode = FilterMode.Bilinear,
                    wrapMode = TextureWrapMode.Clamp,
                    useMipMap = false,
                    autoGenerateMips = false,
                };
                state.giTextures[i].Create();
                //新图内容未定义：清成黑（a = 0 ⇒ 物体着色退回烘焙），免得第一帧/重建帧把垃圾当历史
                buffer.SetRenderTarget(state.giTextures[i], RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
                buffer.ClearRenderTarget(false, true, Color.clear);
            }
        }

        //追踪换算像素、双边取邻居都要按 GI 图**自己的**纹素尺寸（不能沿用 _CameraBufferSize）
        buffer.SetGlobalVector(texelSizeId, new Vector4(1f / width, 1f / height, width, height));

        //本帧的两张中间图（半分辨率 + HDR，和持久图同一套格式）：
        //Trace → _SSGITraceTex，Temporal 之后横竖两趟双边用 _SSGITempTex 倒手
        buffer.GetTemporaryRT(traceTexId, width, height, 0, FilterMode.Bilinear, RenderTextureFormat.ARGBHalf);
        buffer.GetTemporaryRT(tempTexId, width, height, 0, FilterMode.Bilinear, RenderTextureFormat.ARGBHalf);
    }

    ///释放**一台相机**的两张持久 GI 图（重建时、关掉时、相机被销毁/太久没渲染时、Dispose 时用）
    static void ReleaseState (CameraState state)
    {
        for (int i = 0; i < state.giTextures.Length; i++)
        {
            if (state.giTextures[i] != null)
            {
                state.giTextures[i].Release();
                CoreUtils.Destroy(state.giTextures[i]);
                state.giTextures[i] = null;
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

    ///本帧要不要**丢掉历史**（Setup 里、上传参数之前调）。触发点：
    ///  ① 没跑过 / 刚重建（尺寸变也走这条，`AllocateTextures` 会置 `hasHistory = false`）；
    ///  ② 换了相机 ⇒ 由"每个相机一份 state"天然覆盖（新 state 初值就是"要重置"）；
    ///  ③ 相机瞬移 / 急转；
    ///  ④ 外部显式要求（`RequestResetHistory`，切场景）。
    bool NeedResetHistory (CameraState state, Matrix4x4 viewProjection)
    {
        //① 这座相机的图刚建出来、或者还没跑过一趟 ⇒ 历史里是黑的/垃圾
        if (!state.hasHistory)
        {
            return true;
        }

        //③ 瞬移/急转：把"上一帧视野轴上的中景点"用**本帧** VP 再投一次，跑到相机背后或投出屏幕 ⇒ 历史对不上。
        //   （平移和旋转都会让这个点跑 ⇒ 一个判据覆盖两种"瞬移"；不做的话那一下会把屏幕外的老画面拖进来 = 满屏拖影）
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

    ///上传这台相机本帧要用的东西（名字和 shader 里一一对应）
    void SetParameters (CommandBuffer buffer, CameraState state, ScreenSpaceIndirectDiffuseSettings settings,
        Vector2 jitter)
    {
        //上一帧 VP：Temporal 那趟拿它把本帧像素投回上一帧的屏幕位置（没运动矢量，重投影全靠它）
        //⚠️ 重置那一帧没有可信的"上一帧"（而且该字段初值是**零矩阵**、不是单位阵）⇒ 直接传本帧的：
        //   此时 shader 那边本来就会丢掉历史，传什么都不被采，但至少不会让逆矩阵/除法炸出 NaN。
        buffer.SetGlobalMatrix(prevViewProjId, state.resetHistory ? state.currentViewProjection : state.previousViewProjection);

        buffer.SetGlobalFloat(rayCountId, settings.rayCount);
        buffer.SetGlobalFloat(rayLengthId, settings.rayLength);
        buffer.SetGlobalFloat(stepCountLimitId, settings.stepCountLimit);
        buffer.SetGlobalFloat(thicknessId, settings.thickness);
        buffer.SetGlobalFloat(screenFadeId, settings.screenFade);
        buffer.SetGlobalFloat(intensityId, settings.intensity);
        buffer.SetGlobalFloat(temporalWeightId, settings.temporalWeight);
        buffer.SetGlobalFloat(temporalScaleId, settings.temporalScale);
        buffer.SetGlobalFloat(motionBlendScaleId, settings.motionBlendScale);

        //STBN：没配图就绑白图 + 开关 0（shader 里 `lerp` 会退回程序化的 R2 序列，不会崩）
        buffer.SetGlobalTexture(blueNoiseId, settings.blueNoise != null ? settings.blueNoise : Texture2D.whiteTexture);
        buffer.SetGlobalFloat(blueNoiseEnabledId, settings.blueNoise != null ? 1f : 0f);
        //本帧取第几片：复用那个 64 帧的 Halton 计数器（图集正好 64 片，天然对齐）
        buffer.SetGlobalFloat(sliceIndexId, state.randomSampleIndex);
        buffer.SetGlobalFloat(blurRadiusId, settings.blurRadius);
        buffer.SetGlobalFloat(debugIndirectId, settings.debugIndirect ? 1f : 0f);
        buffer.SetGlobalFloat(otherLightLimitId, settings.otherLightLimit);
        //RandomOffset：xy = 本帧的随机种子偏移，z = "这帧丢掉历史"（Temporal 那趟判它；不新加 uniform）
        buffer.SetGlobalVector(randomOffsetId,
            new Vector4(state.randomOffset.x, state.randomOffset.y, state.resetHistory ? 1f : 0f, 0f));
        //本帧 TAA 抖动：Temporal 里 `historyUV += _SSGIJitter.xy;`（和 TAA 那行同款）
        buffer.SetGlobalVector(jitterId, jitter);
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
}
