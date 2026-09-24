# MEMORY（长期记忆）

## 项目
- Unity **2023.2.20f1c1**，自定义 SRP「**Argonara RP**」（Catlike 风格教学向管线），代码在 `Assets/ArgonaraRP`；
  管线资产：`Assets/Settings/Argonara Render Pipeline Asset.asset`；阴影核心：`Runtime/Shadows.cs`、`ShaderLibrary/Shadows.hlsl`。
- **用户会同时用别的 AI 改同一批文件**：我改过的东西被回退/覆盖过多次。**动手前必须先读当前文件状态**，不要凭上一轮的记忆直接改。
- 用户能看 git（GitHub Desktop 的前端就是 `git diff`，我能读同一份数据）；Rider 的 Local History 存在 %APPDATA% 下，读不到。

## 用户偏好
- **回答要短**：先给结论，再一两句理由；不要长清单、不要长篇分析（多次要求"简单说"）。
- **还要"通俗"（2026-09-18 明确）**：不要长表格、不要分点罗列的分析过程；**要用大白话 + 打比方**把原理讲清（例：Hi-Z 的问题是"迈大步、只看落脚点"，就漏了中间）。看**不懂**和**太长**一样算失败。
- 改代码偏好**最少、非破坏性**的改动；改完要自检（lint/编译）并说明**怎么验证**。
- **严格按用户列举的范围改**：顺带发现的"死字段/死代码/过时注释"要先**报告并等确认**，不要自己顺手删（2026-09-11 我顺手删了因此变成只写字段的
  `ShadowedDirectionalLight.nearPlaneOffset`，被质问"不是没让你这样干吗"）。
- 提"咋回事"这类问题时：先解释原因 + 给方案，再问是否动手；一旦说"改吧"就直接改完。
- **不要什么都往 memory 里写**：只记有跨会话价值的结论/约定，别把每轮的清单细节、分析过程搬进去（用户明确提过）。
- **不要写自定义 `PropertyDrawer`**（加过两次都被否："改的太多""别加 drawer 了"）。要在 Inspector 里分组，就用 `[System.Serializable]` 嵌套结构体；
  字段归类重命名时**必须同步改管线资产 `.asset` 里的键**（否则用户调好的值会被重置）。
- **渲染路径的定位（2026-09-15 用户定调）**：**延迟 = 全功能主路径**，屏幕空间类效果（SSR 等）只在这里做；
  **前向 = 基础光照兜底路径**（MSAA/透明/VR/移动），**不要求与延迟特效对等**。用户明确表示"不想继续为前向补 SSR 细节（粗糙度→mip）"。
  ⇒ 以后不要主动提议"让前向也支持某屏幕空间效果"，除非他问；前向 SSR 保持现状（清晰档 mip0）即可。
  （与业界一致：PPSv2 / URP / HDRP 的 SSR 都是 **deferred-only**。）
  前向 SSR 的完整差异/未做点/注意事项清单在 `2026-09-15.md` 的「前向 SSR 相对延迟的差异」一节
  （要点：**晚一帧** / **无粗糙度→mip（永远 mip0）** / **无 composite、只对走了这套 Lit 的物体生效** / **多一趟 depth-normal prepass、法线精度低** / **两张持久 RT 双缓冲 + 两个"有没有图"开关每帧必须显式设**）。

## 技术约定（本项目）
- ⭐⭐ **不要用 `InterleavedGradientNoise` 取"两个随机数"（2026-09-24 踩过，症状极隐蔽）**：
  IGN 本质是**一维**低差异噪声 —— `IGN(p + 常数)` 只是"同一个序列的另一个相位"，
  所以 `float2 u = float2(IGN(seed), IGN(seed + d))` 的两个分量**强相关**。
  更糟的是本项目原来用的 `d = 13.7`：内层 `dot(p, magic.xy)` 的增量 = 13.7 × (0.06711056+0.00583715) = **0.99938 ≈ 1**，
  被内层 `frac` 吃掉 ⇒ 两个值**几乎完全相等**（差 ≈ 0.03）⇒
  `SsgiCosineHemisphere` 里 `abs(u2.x) > abs(u2.y)` 恒为假、`theta` 恒为 π/4 ⇒ **半球方向塌成一条固定竖直平面里的弧**
  ⇒ SSGI 的 GI patch 变成"**被压扁、只朝一个方向、且不随相机转动**"，而且 `rayCount` 1 和 16 看不出差别。
  ✅ 正确做法：需要 ≥2 维随机就用 **R2 低差异序列**：`u = frac(phase + float2(0.7548776662, 0.5698402909) * i)`
  （`phase` 可由 IGN 给、每帧再叠 Halton 相位）；或至少让两个 IGN 输入**不是"同一点 + 常数"**（如交换轴 `.yx`）。
- ⭐ **STBN 图集要用"每帧随机跳位"（`Tools/generate_blue_noise.py --mode jitter`，现为默认），别用"每帧固定平移"的滚动版（`--mode scroll`）**：
  滚动版统计指标同样好（切片频谱不变、lag1 ≈ −0.17），但图案**整体匀速平移** ⇒ 画面上看是"在流动"（2026-09-24 用户实测报"GI 在流动"）。
  规律：**任何"一致方向"的偏移都会被眼睛抓成运动**；随机跳位指标一样好、观感只剩"沙沙"噪声。`--mode 3d` 也不用（切片单独看不是空间蓝噪声，低频/白噪声 0.6~0.97）。
  图集 = 512×512（8×8 个 64×64 切片，行自下而上）；资源 `Textures/STBN64.png`（**单通道复制到 RGB**，Point / 不压缩 / 无 mip，sRGB 关）。
- ⭐ **采样器必须用工程里自己声明的那几个（2026-09-24 踩过）**：本工程只在 `ShaderLibrary/Common.hlsl` 声明了
  `SAMPLER(sampler_linear_clamp); SAMPLER(sampler_point_clamp);`（另加 `Shadows.hlsl` 的 `sampler_linear_clamp_compare`、
  `Fragment.hlsl` 的 `sampler_CameraColorTexture`）。**别照抄 URP/HDRP 的 `sampler_point_repeat` / `sampler_linear_repeat`** ——
  未声明的采样器 = **shader 编译错误** ⇒ 该 shader 的 pass 全部失效 ⇒ **FD 里连绘制都不出现、效果整条消失**
  （2026-09-24 SSGI 就这么"消失"的）。要 Repeat 就自己在**纹素坐标上 `fmod` 绕回**，用现成的 `sampler_point_clamp`。
  排查口诀：**FD 里连 draw 都没有 ⇒ 先看 Console 的 Shader error，别先查 C#**。
- **帧调试器（FD）分组规则（2026-09-24 立）**：`ExecuteCommandBuffer(buffer)` 生成的**外层组名 = 执行那一刻的 `buffer.name`**；
  `BeginSample/EndSample` 只是往里再套一层。⇒ 每次要执行之前**先**把 `buffer.name` 设成想要的组名，**执行之后**再恢复成 `bufferName`；
  特性自己的 `Draw` 改完名字**不要在里面还**（否则会被上一层名字包住、FD 里看不出是它画的）。
  踩过的两个症状：SSR/SSGI 那段的外层显示成 "Screen Space SSGI"（看起来把 Hi-Z/SSR 包住了，其实只是同一段命令）；
  TAA 被 "Render Camera Deferred" 包住（因为 `taa.Draw` 自己把名字还了）。修法：延迟那边执行前设 `buffer.name = "Screen Space Effects"`；
  `TemporalAntiAliasing.Draw` 不再还名字、由调用方在 ExecuteBuffer 之后恢复。
- 阴影里凡是"**半径 / 模糊 / 偏移**"一律用**世界单位（米）**；级联相关的量**只允许**出现在"米 → 本級联纹素/UV"的换算那一步。
  违反这条就会出现"级联交界处模糊突变"（历史上反复踩过：搜索半径、半影、ratio 分母都踩过）。
- **给序列化字段（`ShadowSettings`）改名 = 三件套一起改**：① C# 字段名 ② 管线资产 `.asset` 里对应的键 ③ 成对检查 `Shadows.cs` 上传的 uniform 名与 `Shadows.hlsl` 里声明的名字。
  漏掉任何一处都会静默失败（值变 0 → 代码回落默认值 / uniform 没人写），症状就是"滑条调了没反应"。（2026-09-11 踩过）
- 新增 PCSS/阴影调参优先做成 **uniform**（能运行时改），**不要加 shader keyword**（会炸变体数）。
- 级联球调试：`Shadows.ComputeDebugCascadeSpheres`（与渲染路径共用 `ComputeCascadeSphereGeometry`，几何口径一致）。
- 关键词相关：定向光与其他光共用 `_SHADOW_PCF3/5/7`；`_DIRECTIONAL_PCSS` 是独立 keyword（只对主定向光生效）。
  阴影滤波档位 `ShadowSettings.filter` 已**提到顶层统一控制**（定向光 + 其他光共用一个档位）。
- PCSS 的两个"锚点"参数（`pcssSearchAnchorTexels` / `pcssPenumbraAnchorTexels`）单位是"**最细级联的纹素数**"，
  所以**必须随 tileSize 成比例**（512→约 10/20，1024→约 20/40）；换算后的世界长度才是真正生效的量。

## 渲染层（Rendering Layer）约定（2026-09-15 立）
- 本管线**只支持 8 个渲染层**、**掩码方案**（一个物体/一盏灯可同时在多层，判定 = 位掩码按位与）。
  单一来源：`Runtime/RenderingLayers.cs`（`Count=8`/`Limit=0xFF`/`DefaultNames`）＋ `ShaderLibrary/Surface.hlsl` 的
  `RENDERING_LAYER_COUNT/MASK` + `EncodeRenderingLayers/DecodeRenderingLayers`。**改层数要同步改这两处。**
- **延迟下逐物体的 `unity_RenderingLayer` 无效**（光照 pass 是全屏 `DrawProcedural`，那是逐 draw 常量且来源不可靠，
  会被前面的全屏 pass 写成 0 ⇒ `RenderingLayersOverlap` 把每盏灯都挡掉 ⇒ **全黑**；2026-09-15 踩过）。
  所以物体的层掩码**写进 GBuffer3(RMO) 的 A 通道**（8 位：`mask/255` 存、`(uint)(a*255+0.5)` 读；GT3 是 ARGB32+Linear，无损），
  延迟光照 pass 读回来。**前向不需要**（跟着真实物体绘制，`unity_RenderingLayer` 本来就有值）。
- 编辑器层数上限靠 **`ArgonaraRenderPipelineAsset.renderingLayerMaskNames`**（返回 8 个名字）：Unity 自带的物体/灯光
  Rendering Layer Mask 下拉框、以及本管线相机掩码字段（`RenderingLayerMaskDrawer`）都按这个列表长度决定显示几项。
- Unity 两家做法（已核对源码）：**URP** 渲染层放**独立 GBuffer slice**（`GBufferRenderingLayersIndex=5`，格式按层数 R8/R16/R32），
  灯侧逐灯 `_LightLayerMask` uniform，判定在像素着色器；全屏光照 pass 是**逐灯**不是逐层；stencil 只放材质位 + `StencilLight`。
  **HDRP** 渲染层放 GBuffer 的 A 通道（Light Layer），stencil 被 unlit/deferred/SSS/SSR/decal/motion vector 占满。
  ⇒ **两家都不用 stencil 存渲染层**（"URP 用 stencil 存渲染层"曾是错误说法，已作废）。

## TAA（2026-09-21 移植完成、已出效果）
- `Runtime/TemporalAntiAliasing.cs` + `Shaders/TemporalAntiAliasing.shader`（单文件单 pass；素材 = 用户给的 built-in 版 `TAA张亚坤.shader`）。
  **状态每个相机一份**（Game/Scene 各自攒；反射/预览相机排除）。本版是"仅重投影"，运动矢量那套留在 `//#define TAA_MOTION_VECTORS` 开关里。
- **两条必守的时序铁律**：① 抖动注入在 `SetupCameraProperties` **之前**；② 还原 `camera.projectionMatrix` 在 `Submit()` **之后**
  （Submit 之前还原 ⇒ 整帧未抖动 ⇒ 表现为"无 AA + 历史错配的糊"）。
- 历史 uv = 重投影 + `+= _TAAJitter`（不加回抖动 = 每帧落在不同亚像素偏移处 ⇒ 反馈回路里每帧低通 ⇒ 糊）。
- 名字坑：SRP core 的 `Color.hlsl` 已有 `RGBToYCoCg`/`YCoCgToRGB` ⇒ 我们的叫 `TaaRGBToYCoCg`/`TaaYCoCgToRGB`。
- 未做：运动矢量（动的东西会拖）、锐化（`sharpenStrength` 上传了没接）、TAA 在后处理**之前**（非教程的 tonemap 之后）。
- ✅ **没有"抖动泄进阴影"这回事（2026-09-24 复核后自我更正）**：`Shadows` 确实从 `camera.projectionMatrix` 反推相机视锥
  （`ComputeDirectionalShadowMatricesAndCullingSphere` 的 cascadeIndex==0 缓存、`RefreshPCSSRadiusMetrics`、`ComputeDebugCascadeSpheres`），
  但**调用顺序保证它拿到的是未抖动的矩阵**：两个渲染器都是 `lighting.Setup(...)`（内含 `shadows.Setup` + `shadows.Render()` = 级联拟合 + 阴影贴图渲染）
  **在** `Setup(...)` 注入抖动**之前**，且帧末 `Submit()` 之后才 `RestoreProjection()`。
  ⇒ **这条顺序是隐式依赖，改渲染顺序时别把 `lighting.Setup` 挪到抖动之后**（挪了就会出现"远处阴影/物体震"）。


## SSGI（2026-09-22 起，进行中；**只做延迟**）
- `Runtime/ScreenSpaceIndirectDiffuse.cs`（`Setup/AllocateTextures/Draw/Cleanup/ReleaseTextures/Dispose` 都已实现）
  + `ScreenSpaceIndirectDiffuseSettings.cs` + `Shaders/ScreenSpaceIndirectDiffuse.shader`（4 个 pass 的壳）
  + `Shaders/ScreenSpaceIndirectDiffuse.hlsl`（**四个 pass 全部实现**：Trace / Temporal / BlurX / BlurY）。
  管线资产 `.asset` 已把 SSGI 绑上并 `enabled: 1`（shader guid `176f29d07ddbda740a9a41602532dd11`）⇒ 进 **Game 视图**就能看到。
  Shader 名 = **`Hidden/ArgonaraRP/Screen Space Indirect Diffuse`**。
- **Trace 趟的口径（和 CGBull 不同的两处，都是故意的）**：
  ① 输出 **`rgb = 命中射线平均出来的辐照度`、`a = 可信度`（命中率 × 屏幕边缘淡出）**；
  ⚠️ **没命中的射线什么都不贡献**（2026-09-22 实测后改的：原来塞 `SampleLightProbe` 是**无条件**的 ⇒ 遮挡处也被照亮 = 漏光），
  平均时除的是**命中根数**而不是总根数（否则"命中率低"会被打折两次）
  —— 因为消费端是 `lerp(烘焙, rgb, a)`，rgb 再乘一次 mask 等于把可信度算两遍（会变暗）；
  CGBull 是把"GI×mask + 眼深度"打包进 rgba 给他的双边当权重用，我们的深度直接从 `_CameraDepthTexture` 采。
  ② 命中点**不采 GBuffer4**（它是 `emission + 间接光`，当"射出的光"会把间接光算两遍）⇒ 只用 `albedo(GBuffer1) × 主光(N·L × 阴影)`；
  真正的 emission/所有光源要么单独存一张图、要么以后做"只含直接光的拷贝"。
- **命中点的直接光（2026-09-24 扩）**：主光（第一个定向光）**+ 最近的 N 盏点光/聚光**（设置 `otherLightLimit`，`[Range(0,8)]` 默认 2，0 = 关）。
  取灯方式：扫全部 `_OtherLightCount` 只算距离平方（超灯范围 `distSqr * _OtherLightPositions[i].w >= 1` 跳过）→ 固定 8 槽有序表（常量索引、不 spill）
  → 前 limit 槽调 `GetOtherLight(i, hit, shadowData)`（自带 range/spot 衰减 + 阴影）。数据全在 `Light.hlsl` 的 CBUFFER 里 ⇒ C# 只上传上限。
- ⚠️ **阴影关键字（2026-09-24）**：SSGI 的 **Trace pass** 声明了 `#pragma multi_compile _ _RECEIVE_SHADOWS`（不加的话
  `GetDirectionalShadowAttenuation`/`GetOtherShadowAttenuation` 开头的 `#if !defined(_RECEIVE_SHADOWS) return 1.0` 会让**命中点完全没阴影**）。
  **故意不声明** `_SHADOW_PCF3/5/7` 和 `_DIRECTIONAL_PCSS`（保持最便宜的硬件 PCF2x2：我们的阴影查询 ≈ 9 次/像素 vs 光照 pass 的 1 次）。
- Trace 的实现细节：Shirley 同心圆盘 → cosine 半球（世界空间，TBN 以法线为 z）；`pixelPos + i*37 + Halton偏移` 喂 IGN 取两根射线随机数；
  Hi-Z 步进**照 SSR 那套**（基准步长 1 像素、升/降档规则、每步采"中点+末端"两格、`_SSGIThickness` 判命中、起点沿法线抬 0.01 防自交、
  朝相机飞的射线按近平面截断）；单根射线先 `c/(1+Lum)` 压、平均后 `/(1-Lum)` 还原（防 firefly，对单根值完全可逆）；
  `hitFraction × 屏幕边缘淡出` 当可信度。函数都带 `Ssgi` 前缀（以后抽公共库不撞名）。
- ⭐ **背面剔除（2026-09-24 取代了原来的"朝向惩罚"）**：`SsgiLoadHit(hitUV, dirVS)` 用**几何面法线**（`ScreenSpaceGeometricNormal`，
  深度邻居重构）判 `dot(dirVS, geoVS) < 0`；**不是**软权重 —— 假命中 `continue`（不加辐照度也不加命中率）⇒ 该处可信度掉下去 ⇒ 退回烘焙。
  ⚠️ 千万别退回"用着色法线（GBuffer2）算 `1-saturate(dot)`"的老写法（法线贴图一花就误判 ⇒ 闪点；而且是"按 0 贡献算进平均" ⇒ 白白压暗 GI）。
  `SsgiShadeHit` 同时改成接收 `SsgiHit`（深度/法线不再重复采样）。
- `_SSGIDebugIndirect > 0.5` ⇒ 可信度强制 1（= 物体着色整块用 GI，能单独看间接光）。
- **时间累积（`TemporalPassFragment`，2026-09-22 做）**：和 TAA 同一套 —— 深度 + `_SSGIPrevViewProj` 重投影（含
  `#if UNITY_UV_STARTS_AT_TOP historyUV.y = 1 - historyUV.y` 那次翻转）**+ `historyUV += _SSGIJitter.xy;`** →
  `SsgiCompress` 压缩域里做 3×3 邻域 AABB（YCoCg）+ `SsgiClipHistory` 软裁剪 →
  `blend = saturate(1 - _SSGITemporalWeight + length(uv - historyUV) * _SSGIMotionBlendScale)` → `SsgiUncompress` 还原；
  `historyUV` 出屏或 `history.a < 0.001`（上一帧那格没数据）⇒ `blend = 1`；天空直接返回 0；`_SSGIRandomOffset.z > 0.5` 时只输出当前帧。
- ⭐ **重投影必须回补"本帧 TAA 抖动"（2026-09-24 补；TAA 早就有这行、SSGI 当初漏了）**：`_SSGIPrevViewProj` / `_TAAPrevViewProj`
  都是**未抖动**的 VP（`GL.GetGPUProjectionMatrix(originalProjection, true) * worldToCameraMatrix`）⇒ 投出来的历史 UV 天然带一个 −j，
  shader 里必须把 j 加回去（`historyUV += _SSGIJitter.xy;`，位置和 TAA 那行一样，在 y 翻转之后）。
  链路：`CameraRendererDeferred.Setup` 里 `useTAA ? taa.GetJitterUV(camera) : Vector2.zero` → `ssgi.Setup(..., jitter)` → `_SSGIJitter`。
  漏了的症状：**静止不动画面也在抖**（历史每帧被采偏 ~0.25 个半分辨率纹素，还会把历史跟邻居混着用 ＝ 稀释累积）。
- ⚠️ **抖动/噪声的观感被 `intensity` 一起放大**：`.asset` 里 `intensity: 8` 是"天空项 + AO 还没做"的补偿，GI 的噪声也被 ×8
  ⇒ 用户实测「调成 1 看起来很自然」。**治本 = 把天空命中（待办①）做出来再让 intensity 回落**，别靠抠滤波参数硬压。
- **命中点的 emission 已接**（方案 A：单独一张 `_GBuffer5 = emission`，物体着色时顺手写）：`SsgiShadeHit` 末尾 `+ PI × emission`
  （自发光不乘命中点 albedo ⇒ 单独加在最后）。⚠️ 仍**不能**拿 `GBuffer4`（= emission + 该点 indirect，会算两遍）。
  方案 B（"只含直接光"的全屏图，含所有光源、最准）**没做**，也不需要了（现在主光+最近 N 盏其他光都在 shader 里现算）。
- 资源：**半分辨率**、2 张持久双缓冲 GI 图（`ARGBHalf`，固定 HDR）+ 2 张临时图（`_SSGITraceTex` / `_SSGITempTex`，**Setup 借 / Cleanup 还**）。
  pass 顺序 `Trace → Temporal → BlurX → BlurY`（最后一个 pass 直接写"本帧该写的那张持久图"）。
- ⭐ **uniform 约定（用户点名要记）：`resetHistory`（"这帧丢掉历史"）塞在 `_SSGIRandomOffset.z`** ——
  xy = 每帧的 Halton 随机偏移（射线方向必须每帧变），z = reset 标记，**为它不另加 uniform**；shader 的 Temporal 趟靠它跳过历史。
- 时序同 SSR：Setup 把 `_SSGITex` 绑成"上一帧那张"→ Draw 写另一张 → Cleanup 交换索引 + `previousViewProjection = currentViewProjection`。
  ⚠️ 两条和 SSR 不同的铁律：**Temporal 之前不能改绑 `_SSGITex`**（SSR 是 Trace 一开头就改绑，不能照抄）；
  **Draw 结尾必须恢复渲染目标**（否则紧接着的透明物会画进 GI 图）。
- ⭐ **Hi-Z 是管线资产顶层的独立设置（2026-09-24 改，`HierarchicalZSettings hiz`）**：原来塞在 `SSRSettings.hiz` 里、还有自己的 `enabled` 开关；
  现在**顶层一份、SSR / SSGI 共用**，并且**删掉了 `enabled`**（"要不要建"由消费它的特性决定）。
  ⇒ `.asset` 里 `hiz:` 从 `ssr:` 内部**挪到顶层**、去掉 `enabled` 键；SSR 里的 `hizRayOffset`（射线起点偏移）**留在 SSR**（那是 SSR 的追踪参数）。
  `HierarchicalZ.Setup` 的判定只剩 `!use || settings == null || settings.Material == null`。
- ⭐ **"SSR 要不要用 Hi-Z" 是 SSR 自己的开关（2026-09-24 补，`SSRSettings.useHiZ`）**：
  和"资源有没有"（`_HiZEnabled`，由 `hiz.Setup` 上传）**区分开** ——
  shader 里 `if (_HiZEnabled > 0.5 && _SSRUseHiZ > 0.5)` 才用 `traceRayWithHiZ`，否则退回线性 `traceRay`（那套"等步长 + 末尾二分"一直保留着）。
  渲染器的建图条件：延迟 `useSSGI || (useSSR && ssrSettings.useHiZ)`；前向 `useSSR && ssrSettings.useHiZ`
  ⇒ "只开 SSR 且它选线性"时不建 Hi-Z（省下全分辨率 mip 链）；`hiz.Draw` 在没建时自己早退（`material == null`）。
  追踪是半分辨率、Hi-Z 是全分辨率 ⇒ shader 里做 2:1 换算（`_CameraBufferSize.xy * _SSGITexelSize.xy`）。
- **全分辨率开关**：`ScreenSpaceIndirectDiffuseSettings.fullResolution`（关 = 半分辨率，默认）⇒ `AllocateTextures` 按它算尺寸，
  `CameraState` 里也存一份（切换要**重建**两张持久图）；`.asset` 里对应键 `fullResolution`（已加，=0）。
  ⚠️ `blurRadius` 的单位是"GI 图的纹素" ⇒ 全分辨率下同样的半径只盖一半的屏幕范围。
- 📌 **待办（用户 2026-09-22 要求记入记忆）**：**"相机 → 状态表"这一层值得抽成公共类**（泛型 `CameraStateTable<TState>` +
  `ICameraState { Release(); RequestReset(); }`：entry 列表 + 回收策略（被销毁 / 超 `stateKeepFrames` 没用过）+ `RequestReset` 遍历 + `ReleaseAll`，
  约 60~80 行，TAA 与 SSGI 现在**逐字同款**）。**但不要抽每帧流程**（Setup/Draw/Cleanup 的 pass 顺序/贴图格式/双缓冲/参数各效果差异太大）。
  **时机：等第三处出现再抽**（TAA + SSGI 两处；等 **SSR 也改成 per-camera** 就是三处，那时抽最划算）。项目偏好：别过度抽象、保持平铺直叙。
- ⭐ **状态是每个相机一份**（2026-09-22 改，照 TAA 那套 `CameraState`/`Entry`/`GetState`/`FindState`/`stateKeepFrames=60`）：
  GI 图双缓冲、历史 VP、`hasHistory`、随机种子都进 state ⇒ **Game 视图和 Scene 视图各自攒历史**（Scene 视图能直接 debug）。
  `ShouldRender` 放宽成 `IsEligible`（**排除反射 + 预览相机**）；`Draw(buffer, camera, ...)` / `Cleanup(buffer, camera)` 现在都要 `camera`。
  被排除的相机：**只刷 `_SSGITex = 黑图`、半点状态都不碰**（不刷的话它们会沿用别的相机留下的 GI 图 ⇒ 串画面）。
  关掉 SSGI（总开关/shader 为空）⇒ `ReleaseAllStates()`（所有相机的图都放）。
- ⭐ **消费端约定（已接，2026-09-22）**：`GI.hlsl` 的 `GetGI` 里
  `gi.diffuse = lerp(烘焙(lightmap+SH), _SSGITex.rgb * _SSGIIntensity, saturate(_SSGITex.a))`。
  ⇒ **`_SSGITex` 的语义 = `rgb`：间接漫反射的辐照度（和 `SampleLightProbe` 同口径、别乘接收点 albedo，外层 `IndirectBRDF` 还会乘 `k_d × albedo`）+ `a`：可信度（0 = 退回烘焙）**。
  ⇒ 所以 **SSGI 的 shader 必须按这个口径输出**（半分辨率、双线性上采样）。
  `_SSGITex`/`_SSGIIntensity` 声明在 `GI.hlsl`（和 `_SSRTex`/`_SSRIntensity` 同一套路，**没有开关 uniform**：关掉/没接 = 绑 1×1 黑 ⇒ a=0 ⇒ 自动退回烘焙）。
  前向不跑 SSGI，但**必须每帧绑黑兜底**：`ScreenSpaceIndirectDiffuse.BindFallback(buffer)`（在 `CameraRendererForward.Setup` 里调）。
- `resetHistory` 触发点现有：首帧/刚重建（尺寸变）、换相机、**瞬移急转**（照 TAA 那套"上一帧视野轴中景点用本帧 VP 投回屏幕"，
  用 `!resetHistory` 守卫零矩阵）、切场景（`RequestResetHistory`）。
- **未做清单（2026-09-24 盘点；已完成：shader 四趟 / 消费端 / per-camera / 全分辨率 / 其他光源 / 阴影关键字 / 背面剔除）**：
  ① **天空命中（有条件）** —— 收益最高：命中点只有直接光，烘焙里最大的"天空/环境"那项**完全没有** ⇒ 这是"GI 弱、要靠 intensity 硬拉"的根因。
     做法：区分"射线真的打到天空"（UV 在屏内 + 深度 = 远平面）与"射线出屏"，前者给天空辐照度（`unity_SpecCube0` / `SampleSH9` × π）；**出屏依然什么都不给**（否则又漏光）。
  ② **AO 配合**（现在只加不减 ⇒ 角落缝隙不暗）：轻量版 = 用命中率 `a` 去压接收点的 baked 环境光；完整版 = 一趟 GTAO。
  ③ **强度标定 / 替换 vs 叠加**：`.asset` 里 `intensity: 8` 就是"① ② 没做"的补偿；做完后应回到 1~2 或改成在烘焙之上叠加。
  ④ **Motion Vector**（动的东西拖影；同时升级 TAA）。⑤ **性能**：双边抽头 `min(radius,12)` → `min(radius,4~6)`（一行，省 2~3 倍）。
  ⑥ ❌ **`denoise` 参数已删除**（2026-09-24，用户："基本上永远都需要降噪"）—— 先接线成 C# 分支（`if (state.denoise)` 少发三个 draw），
     用户看过之后决定不要这个开关 ⇒ Settings 字段、`CameraState.denoise`、`Setup` 里的拨动重置、`Draw` 的分支、`.asset` 的 `denoise` 键**全部移除**。
     **Temporal + 两趟双边恒定执行**。⇒ 以后别再给它加开关；想对照"裸追踪结果"就临时注释掉 C# 里那三个 draw。
  ⑦ P2：深度/法线引导上采样（减少半分辨率串色）、命中点渲染层过滤、`_SSGIDebugIndirect` 多档、SSR/HiZ 的 per-camera。
- **和 CGBull（参考实现）的差距**：主干（Trace/Temporal/双边/消费）一一对应，我们已经**超出**它的地方 =
  命中点用 GBuffer 着色（它采 SceneColor ⇒ 二次弹射）、其他光源 + 阴影、几何法线背面剔除、双边**带法线权重**（它只有深度）、
  per-camera 状态 + resetHistory 全套、可信度回退烘焙（它屏幕外是黑的）、复用 SSR 的 Hi-Z。
  **它还有而我们没有的只有两件**：① **Motion Vector**（它的 Temporal 靠 MV，我们靠深度重投影 ⇒ 动的东西拖）；② ~~蓝噪声贴图~~（**已补**：2026-09-24 起改用 STBN 图集 `Textures/STBN64.png` + `Settings.blueNoise` 槽，没配则退回 IGN 相位）。
  另：它的 `Combine` 要"把原图里的环境/反射减掉再重加"（避免环境重复叠加），我们是物体着色时就混好 ⇒ 不需要那一步。
