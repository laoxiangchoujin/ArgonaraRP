# Project Memory (ArgonaraRP)

## 项目概述
- Unity SRP 项目，基于 Catlike Coding 教程构建自定义渲染管线
- 项目路径：`d:\Unity\Unity_Projects\ArgonaraRP`
- 资源目录：`Assets\ArgonaraRP\`

## 关键架构
- `ArgonaraRenderPipeline : RenderPipeline` — 主管线（partial class，运行时/编辑器拆分）
- `ArgonaraRenderPipeline.Editor.cs` — 编辑器分部，光照烘焙委托
- `ArgonaraRenderPipelineAsset` — 管线资产，持有 CameraBufferSettings/ShadowSettings/PostFXSettings
- `CameraRenderer` — 逐相机渲染，管理颜色/深度附件、中间缓冲、Gizmos、CopyAttachments
- `CameraBufferSettings` — 管线级缓冲配置（allowHDR, copyColor/copyDepth, reflection 变体）
- `CameraSettings` — 逐相机配置（finalBlendMode, overridePostFX, renderingLayerMask, copyColor/copyDepth）
- `ArgonaraRenderPipelineCamera` — 挂相机上的组件，提供 CameraSettings
- `PostFXStack` — 后处理栈（Bloom + ColorGrading + ToneMapping + LUT）
- `Lighting.cs` — 4方向光+64其他光，渲染层掩码过滤
- `Shadows.cs` — useRenderingLayerMaskTest, ShadowDrawingSettings
- `ReinterpretExtensions.cs` — int/float 位重解释（StructLayout.Explicit 联合体）

## ShaderLibrary 结构
- `Common.hlsl` — 公共函数、sampler、IsOrthographicCamera、OrthographicDepthBufferToLinear、ClipLOD
- `Fragment.hlsl` — Fragment 结构体（positionSS/depth/screenUV/bufferDepth）、GetFragment、GetBufferColor
- `Light.hlsl` / `Lighting.hlsl` / `Surface.hlsl` / `BRDF.hlsl` / `GI.hlsl` / `Shadows.hlsl`
- `UnityInput.hlsl` — UnityPerDraw CBuffer，unity_OrthoParams, _ProjectionParams, unity_RenderingLayer

## 已实现功能清单

### 粒子系统
- `Particles Unlit.shader` — SRPDefaultUnlit + ShadowCaster 双Pass
- **顶点色**：`_VERTEX_COLORS` keyword，COLOR 语义，粒子 Color over Lifetime 等模块写入
- **Flipbook 混合**：Texture Sheet Animation + Custom Vertex Streams(UV2→TEXCOORD0.zw, AnimBlend→TEXCOORD1.x)
- **近平面淡出**：`_NEAR_FADE`，`saturate((depth - dist) / range)` 线性过渡
- **软粒子**：`_SOFT_PARTICLES`，采样 `_CameraDepthTexture` 比较 bufferDepth vs depth
- **扭曲**：`_DISTORTION`，法线贴图解码为屏幕UV偏移，`_DistortionBlend` 控制混合
- **排序**：Renderer → Sort Mode → By Distance（透明粒子远→近）
- **阴影**：Renderer 组件的 Cast Shadows 控制是否执行 ShadowCaster pass

### 后处理管线
- **Bloom**：Additive(叠加) + Scatter(散射) 两种模式，HDR支持，prefilter + 金字塔降采样
- **Color Grading**：曝光→白平衡(LMS)→对比度(LogC)→色彩滤镜→SplitToning(分色调)→ChannelMixer(3×3)→SMH(三段染色)→色相→饱和度
- **ToneMapping**：None / ACES(unity_to_ACES→AcesTonemap) / Neutral / Reinhard
- **LUT**：32³查找表，LogC模式支持HDR(0~59范围)，建表端 LogCToLinear 扩展坐标→查表端 LinearToLogC 压缩
- **ACES空间**：useACES 分支，对比度走 ACES→ACEScc→ACEScg 链
- **Split Toning**：gamma空间 SoftLight 混合，阴影/高光分别染色，balance控制过渡点
- **SMH**：三段权重 × 染色色(HDR可选)，smoothstep过渡

### 多相机与层
- **相机叠加**：FinalBlendMode（One Zero/One OneMinusSrcAlpha），DrawFinal尊重viewport + blend
- **渲染层**：RenderingLayerMask（31层，int.MaxValue解-1），灯光/阴影/物体三层过滤
- **每相机后处理**：overridePostFX + 独立 PostFXSettings
- **每相机深度/颜色纹理**：copyDepth/copyColor 双重开关（管线+相机）
- **反射探针**：CameraType.Reflection 单独控制 copyDepthReflection/copyColorReflection

### 帧缓冲与深度
- **颜色/深度附件分离**：`_CameraColorAttachment` + `_CameraDepthAttachment`，两个独立 RT 共享一个帧缓冲
- **CopyAttachments**：Opaque+Skybox后复制深度/颜色到 `_CameraDepthTexture`/`_CameraColorTexture`
- **CopyTexture vs Draw fallback**：SystemInfo.copyTextureSupport 判断，WebGL 2.0 用 shader
- **Gizmos深度修复**：DrawGizmos前拷贝深度到CameraTarget，恢复Z-Test
- **Tile-based GPU**：分屏时 `camera.rect == fullViewRect ? DontCare : Load`

## 关键概念笔记

### Gamma/色彩空间
- **编码(linear→sRGB)**：`sRGB = linear^(1/2.2)` ≈ ^0.45，值变大变亮
- **解码(sRGB→linear)**：`linear = sRGB^2.2`，值变小变暗（显示器自动做）
- **显示器的^2.2让画面偏暗** → 提前^0.45提亮 → 抵消 → 人眼看到线性正确亮度
- sRGB纹理开启sRGB选项：GPU自动解码(^2.2)，shader拿到正确linear值，所以"变暗"

### Fragment深度
- SV_POSITION在vertex阶段=裁剪坐标(4D)，fragment阶段=屏幕坐标(像素中心+0.5偏移)
- **透视**：`.w` = view-space线性深度（透视除法保留原w）；`.z` = 非线性深度缓冲值
- **正交**：`.z` = 线性0~1（无透视除法）；`.w` = 恒为1
- `IsOrthographicCamera()` = `unity_OrthoParams.w`
- `OrthographicDepthBufferToLinear(z)` = `(far-near)*z + near`（先处理Reversed-Z翻转）

### 渲染层 vs Culling Mask
- Culling Mask：1物1层，SRP下灯光只影响阴影不影响光照，被物理层复用
- Rendering Layer Mask：位掩码，1物可属多层，专属渲染，灵活

### 管线设计原则
- 帧缓冲附件=渲染目标写入端；CopyTexture快照=采样端；读写必须分离
- `GetTemporaryRT` = 分配GPU内存；`SetRenderTarget` = 绑定为帧缓冲
- 中间缓冲仅在 postFX || copyColor || copyDepth 时启用
- 颜色不需要快照副本=因为无消费者需要中途快照+透明物体可直接叠加
- 深度必须快照=透明阶段深度附件继续被Z-Test/Write使用

### Alpha管理
- 不透明物体 `GetFinalAlpha`：ZWrite ON → 强制Alpha=1（忽略贴图alpha）
- Alpha混合 `One OneMinusSrcAlpha`：保证累积正确
- `Blend [_SrcBlend] [_DstBlend], One OneMinusSrcAlpha`：颜色+Alpha分控
