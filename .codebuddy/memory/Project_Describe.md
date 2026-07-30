# ArgonaraRP 项目记忆

## 项目概述
- Unity SRP 项目，基于 Catlike Coding 教程构建的自定义渲染管线
- 项目路径：`D:\Unity\Unity_Projects\ArgonaraRP`
- 资源目录：`Assets\ArgonaraRP\`
- 目录结构：
  ```
  Runtime/           → C# 运行时（Pipeline/CameraRenderer/Lighting/Shadows/PostFX）
  Runtime/Editor/    → Editor 脚本（ShaderGUI、CameraEditor）
  Shaders/           → .shader + .hlsl（Lit/Unlit/Particles/CameraRenderer）
  ShaderLibrary/     → 公共 hlsl 库（Surface/BRDF/GI/Lighting/Shadows/Common...）
  Materials/         → 材质资源
  Scenes/            → 测试场景
  ```

## 关键架构

### 管线核心
- `ArgonaraRenderPipeline : RenderPipeline` — 主管线（partial class 运行时/编辑器拆分），编辑器分部处理光照烘焙委托
- `ArgonaraRenderPipelineAsset` — 管线资产，持有 CameraBufferSettings/ShadowSettings/PostFXSettings，含 `enum RenderingPath { Forward, Deferred }` 资产级开关
- `CameraRenderer` / `CameraRendererDeferred` — 逐相机渲染，二者继承 `CameraRendererBase`，管理颜色/深度附件、中间缓冲、Gizmos、CopyAttachments
- `CameraBufferSettings` — 管线级缓冲配置（allowHDR, copyColor/copyDepth, bicubicRescaling, reflection 变体）
- `CameraSettings` — 逐相机配置（finalBlendMode, overridePostFX, renderingLayerMask, copyColor/copyDepth）
- `ArgonaraRenderPipelineCamera` — 挂相机上的 MonoBehavior，提供 CameraSettings
- `Lighting.cs` — 4 方向光 + 64 其他光，渲染层掩码过滤
- `Shadows.cs` — useRenderingLayerMaskTest, ShadowDrawingSettings
- `PostFXStack` — 后处理栈（Bloom + ColorGrading + ToneMapping + LUT）
- `ReinterpretExtensions.cs` — int/float 位重解释（StructLayout.Explicit 联合体）

### ShaderLibrary 结构
- `Common.hlsl` — 公共函数、sampler、IsOrthographicCamera、OrthographicDepthBufferToLinear、ClipLOD、DecodeNormal、NormalTangentToWorld
- `Fragment.hlsl` — Fragment 结构体（positionSS/depth/screenUV/bufferDepth）、GetFragment、GetBufferColor
- `Surface.hlsl` — Surface 结构体（position/normal/interpolatedNormal/viewDirection/depth/albedo/alpha/roughness/metallic/occlusion/dither/renderingLayerMask）
- `BRDF.hlsl` — BRDF 结构体、直接光 DGF 计算、IndirectBRDF
- `Light.hlsl` / `Lighting.hlsl` / `GI.hlsl` / `Shadows.hlsl`
- `UnityInput.hlsl` — UnityPerDraw CBuffer

### 表面与 BRDF
- `surface.roughness` 直接来自材质（`GetRoughness`），不再做 `roughness → 1-smoothness → 1-smoothness(=roughness) → roughness²` 的 round-trip
- `GetBRDF`：`perceptualRoughness = surface.roughness → roughness = perceptualRoughness² → roughnessSquare = pow(lerp(0.002, 1, roughness), 2)`
- `IndirSpecFactor` 参数改为 `roughness`，`grazingTerm = saturate((1.0 - roughness) + reflectivity)`

### 阴影系统
- 级联阴影：`_CascadeCount`/`_CascadeCullingSpheres`/`_CascadeData` 控制级联选择
- `FadedShadowStrength`：两重淡化（最大距离淡化 + 级联边缘淡化）
- `ShadowData`：cascadeIndex + cascadeBlend + strength；`GetShadowData` 用 `surfaceWS.depth`（线性视空间深度）做级联判定
- Shadow pancaking（ShadowCasterPass z clamp）与 `nearPlaneOffset` 互补
- PCF 滤波：`_DIRECTIONAL_PCF3/5/7`，`_OTHER_PCF3/5/7`
- 级联混合：软混合（双采样 lerp）vs 抖动混合（dither）

### GBuffer / 延迟渲染（Deferred 路径）
- GBuffer 4 张 GT（SV_Target0~3），均为 ARGB32 格式（非 HDR 数据）
  - GT1 = `(albedo, shadingModelID >> 4)`
  - GT2 = `(normal * 0.5 + 0.5, 0)`
  - GT3 = `(roughness, metallic, occlusion, 0)`
  - GT4 = `emission + indirectColor`（含 indirectDiffuse + indirectSpecular + emission，需 ARGBFloat 格式存 HDR 值）
- R11G11B10 精度不足以存高亮度 lightmap 值（mantissa 6bit 在高值区步长过大）
- deferred pass 用 `GetLightingDeferred`（只算直接光），`color += GT4`（间接光+emission 已预合并）
- Shadowmask 在 deferred 下不支持（`gi.shadowMask.shadows = 1.0` 硬编码）
- `_CameraDepthTexture` 在延迟下通过 `SetGlobalTexture` 指向 `_GBufferDepth`
- `unity_MatrixInvVP` 需手动用 `GL.GetGPUProjectionMatrix(proj, true)` 计算后传入

### 后处理管线
- **Bloom**：Additive + Scatter 两种模式，prefilter + 金字塔降采样
- **Color Grading**：曝光→白平衡(LMS)→对比度(LogC)→色彩滤镜→SplitToning→ChannelMixer(3×3)→SMH(三段染色)→色相→饱和度
- **ToneMapping**：None / ACES / Neutral / Reinhard
- **LUT**：32³ 查找表，LogC 模式支持 HDR(0~59)，建表端 LogCToLinear 扩展坐标→查表端 LinearToLogC 压缩
- **渲染缩放**：scale≠1 时先做 ColorGrading+ToneMapping 到 `_FinalResult`（LDR），再用 Pass.FinalRescale 缩放到屏幕——LDR 插值避免 HDR 锯齿与色带
- **Bicubic Rescaling**：`_CopyBicubic` keyword 控制双线性/双三次切换

### 粒子系统
- `Particles Unlit.shader` — SRPDefaultUnlit + ShadowCaster 双 Pass
- 功能：顶点色、Flipbook 混合、近平面淡出、软粒子、扭曲、阴影

### Shader 文件与 Pass 一览
- **Lit.shader** — 4 Pass：`ArgonaraLit`(Forward) / `ShadowCaster` / `Meta` / `ArgonaraGBuffer`
- **Unlit.shader** — 3 Pass：`ArgonaraUnlit`(Forward) / `ShadowCaster` / `Meta`（较 Lit 简化，无法线/detail/mask/emission）
- **CameraRenderer.shader** — 3 Pass：`Copy` / `Copy Depth` / `Deferred Lighting`（全屏四边形，Hidden 不显示在 Inspector）
- **Particles Unlit.shader** — 2 Pass：`SRPDefaultUnlit` / `ShadowCaster`

### Lit Shader（核心 Lit 材质）
- **关键字系统**：`_CLIPPING` / `_NORMAL_MAP` / `_MASK_MAP_NONE/SINGLE/SEPARATE` / `_EMISSION` / `_DETAIL_MAP` / `_PREMULTIPLY_ALPHA` / `_RECEIVE_SHADOWS`
- **Shadows**：`[KeywordEnum(On, Clip, Dither, Off)]` → `_SHADOWS_CLIP` / `_SHADOWS_DITHER`
- **RMO 遮罩**：None（无遮罩）/ Single（单张图 RGB=Roughness/Metallic/Occlusion）/ Separate（三张贴图各取 .r）
- **Detail**：`GetDetail` 返回 float（取 `.r` 通道），中性灰 0.5 → 0.0（无变化），`[-1,1]` 范围表示减/加，同时影响 albedo + roughness + normal
- **Emission**：`_EMISSION` keyword 守卫，Meta Pass 需同样声明 `#pragma shader_feature _EMISSION`
- **预乘 Alpha**：`GetBRDF(surface, true)` 将 `brdf.albedo *= surface.alpha`；Blend 状态 `[_SrcBlend] [_DstBlend], One OneMinusSrcAlpha`

### Meta Pass
- 需手动声明关键字：`_EMISSION` / `_DETAIL_MAP` / `_MASK_MAP_SINGLE _MASK_MAP_SEPARATE`，否则 emission 烘焙为黑
- `unity_MetaFragmentControl.x` = diffuse 路径；`.y` = emission 路径
- Detail UV 在 Meta Pass 中未传入（`c.detailUV = 0.0`），小 bug

### ShaderGUI
- `ArgonaraShaderGUI : ShaderGUI`，自定义 Inspector 分组布局
- `DrawGroups()` 手动绘制分组属性，`FilterHiddenProperties()` 排除重复属性给 `base.OnGUI`
- 分组为 `FoldoutGroup(ref bool, title, Action)` 辅助方法封装（`BeginFoldoutHeaderGroup` + 自定义 `GUI.backgroundColor` + indentLevel + 组间距 2px）
- `TexturePropertySingleLine` 纹理+滑条/颜色并排；`TexturePropertyWithHDRColor` 纹理+HDR 颜色并排

### 其他功能
- 多相机叠加（FinalBlendMode）、渲染层（31 位掩码）、逐物体灯光（`_LIGHTS_PER_OBJECT`，`unity_LightIndices` 最多 8 灯）
- 帧缓冲分离（`_CameraColorAttachment` + `_CameraDepthAttachment`），CopyAttachments（CopyTexture → Draw fallback）
- 逐相机后处理 override、反射探针、Gizmos 深度修复

## 关键概念

### 渲染层 vs Culling Mask
- Culling Mask：1 物 1 层，SRP 下灯光只影响阴影不影响光照
- Rendering Layer Mask：位掩码，1 物可属多层，灯光/阴影/物体三层过滤

### Alpha 管理
- ZWrite ON → `GetFinalAlpha` 强制 Alpha=1
- `Blend [_SrcBlend] [_DstBlend], One OneMinusSrcAlpha`
- 颜色 + Alpha 分控混合

### 调试陷阱
- `#pragma fragment` 函数名必须与 hlsl 定义**精确一致**，否则该 pass 编译失败、对应分支黑屏（如 Rescale pass `CopyPassFragmentRescale` vs `FinalPassFragmentRescale`）
- 中间 RT 句柄 vs shader uniform：`Shader.PropertyToID("_FinalResult")` 只是 C# 端 RT 标签，shader 不认；需通过 `SetGlobalTexture(_PostFXSource, rtId)` 复用既有全局纹理通道
- `NormalTangentToWorld` 结果需 `normalize`，因 TBN 矩阵基于插值后的 `normalWS`/`tangentWS` 构建，非正交基
- 关键字系统：所有 Pass 的关键字声明需一致，否则 keyword 残留（如 None 模式下 `_MASK_MAP_SINGLE` 仍激活）
- GBuffer GT 存储 HDR 数据（间接光/emission）需 ARGBFloat，ARGB32 会钳位 >1 值，R11G11B10 高值区精度不足
- GPU 死循环：`for (j < j < min(...))` 多打了 `j <` 导致 Unity 卡死
- 阴影矩阵：`ConvertToAtlasMatrix` Z 行需做 `[-1,1]→[0,1]` 映射，否则深度比较全错、阴影全黑
- Occlusion 计算：`lerp(1.0, occlusion, _OcclusionSlider)`——strength=1 取完全 AO 值；无 mask 时 occlusion=1.0，slider 不起作用
