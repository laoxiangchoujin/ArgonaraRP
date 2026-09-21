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
