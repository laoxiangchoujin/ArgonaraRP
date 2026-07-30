# ArgonaraRP 实现细节

## 阴影系统细节

### 阴影矩阵
- `ConvertToAtlasMatrix` 中 Z 行需加上 `0.5*(m20+m30)` 做 `[-1,1] → [0,1]` 映射，否则 `SAMPLE_TEXTURE2D_SHADOW` 深度比较全错（阴影全黑）
- `filterSize = texelSize * (filter + 1)`；法线偏移同步放大；`cullingSphere.w -= filterSize` 防 PCF 采样越界
- 逐物体灯光索引：`unity_LightIndices`（2 个 float4 压入最多 8 个灯号），`unity_LightData.y` 表示影响本物体的光源数

### 阴影级联
- `_ShadowDistance` 剔除替代纯裁切球剔除，减少阴影突变
- `_CascadeData` 传递预计算倒数省 GPU 除法
- 最外层裁切球边界硬突变：`cascadeIndex` 越界（=4）导致读取错误矩阵

## 后处理细节

### Bloom
- `DoBloom` 用 `bufferSize`（非 `camera.pixelWidth`）计算金字塔尺寸
- `bloom.ignoreRenderScale` 可让 bloom 用物理像素半分辨率
- prefilter 始终半分辨率；bloomResultId 保持全分辨率（与 source 合成需同分辨率）

### Color Grading 顺序
曝光 → 白平衡(LMS 空间色适应) → 对比度(LogC) → 色彩滤镜 → SplitToning(阴影/高光分别染色, SoftLight 混合) → ChannelMixer(3×3 矩阵) → SMH(三段权重×染色色) → 色相偏移 → 饱和度

### ACES
- useACES 分支：对比度走 ACES → ACEScc → ACEScg 链
- `unity_to_ACES` 矩阵转换 → `AcesTonemap`

## 粒子系统

- **Flipbook Blending**：Texture Sheet Animation + Custom Vertex Streams（UV2→TEXCOORD0.zw, AnimBlend→TEXCOORD1.x），`_FLIPBOOK_BLENDING` keyword
- **Near Fade**：基于 fragment depth 的线性 alpha 衰减，`_NEAR_FADE` keyword，`saturate((depth - dist) / range)`
- **Soft Particles**：采样 `_CameraDepthTexture` 比较 bufferDepth vs depth，`_SOFT_PARTICLES` keyword
- **Distortion**：法线贴图→屏幕 UV 偏移，`_DISTORTION` + `_DistortionBlend`
- **排序**：Renderer → Sort Mode → By Distance（透明粒子远→近）
- **阴影**：Renderer 组件的 Cast Shadows 控制 ShadowCaster pass 开关

## 渲染管线初始化流程

```
ArgonaraRenderPipeline.Render()
  ├─ Asset 层面准备 RT/Settings
  ├─ 创建 LightLoop（方向光 + 其他光）
  ├─ CameraRendererDeferred.Render() 或 CameraRenderer.Render()
  │   ├─ Setup → 创建/配置 RT（color, depth, GBuffer）
  │   ├─ DrawVisibleGeometry
  │   │   ├─ 不透明 → RenderLoop.RenderShadows → Draw(不透明 Pass)
  │   │   └─ 天空盒 + 半透明 → Draw(透明 Pass)
  │   ├─ 延迟模式：
  │   │   ├─ Draw(GBuffer Pass, opaque) → 填充 4 张 GT
  │   │   └─ Draw(Deferred Lighting Pass) → 全屏光照
  │   ├─ CopyAttachments（深度/颜色纹理快照）
  │   ├─ PostFXStack 后处理（Bloom/ColorGrading/ToneMapping）
  │   └─ DrawFinal → 输出到 CameraTarget
  └─ Dispose → 释放临时 RT
```

## 文件清单（.shader + .hlsl）

### Shaders/ 目录
- `Lit.shader` / `LitInput.hlsl` / `LitPass.hlsl` — Lit 材质的 Shader / 输入函数 / 光照 Pass
- `Unlit.shader` / `UnlitInput.hlsl` / `UnlitPass.hlsl` — Unlit 材质
- `Particles Unlit.shader` / `ParticlesUnlitInput.hlsl` / `ParticlesUnlitPass.hlsl` — 粒子
- `ShadowCasterPass.hlsl` — 阴影投射 Pass（Lit/Unlit 共用）
- `MetaPass.hlsl` — 光照烘焙 Pass（Lit/Unlit 共用）
- `CameraRenderer.shader` / `CameraRendererPasses.hlsl` — 后处理 + 延迟光照
- `PostFXStack.shader` / `PostFXStackPasses.hlsl` — 后处理 Blit Pass

### ShaderLibrary/ 目录
- `Common.hlsl` — 公共函数、sampler、ClipLOD、DecodeNormal、NormalTangentToWorld
- `Fragment.hlsl` — Fragment 结构体、深度/UV 工具
- `Surface.hlsl` — Surface 结构体
- `BRDF.hlsl` — BRDF 结构体、DGF、DirectBRDF、IndirectBRDF、IndirSpecFactor
- `Light.hlsl` — Light 结构体、方向光/点光/聚光获取函数
- `Lighting.hlsl` — GetLighting（直接光+间接光循环）、GetLightingDeferred（仅直接光）
- `GI.hlsl` — GI 结构体、光照贴图/探针/环境采样
- `Shadows.hlsl` — ShadowData、级联阴影、PCF 滤波、阴影遮罩

## 渲染器架构

### GBuffer 延迟渲染决策
- 采用复制 `CameraRenderer.cs` → `CameraRendererDeferred.cs` 方案，继承 `CameraRendererBase`
- GBuffer 的 RT / static ID / 光照 pass 材质全部声明在 `CameraRendererDeferred` 内部，前向类零污染
- `ArgonaraRenderPipelineAsset` 加 `enum RenderingPath { Forward, Deferred }` 资产级开关
- GBuffer RT 按帧在 `Setup` 用 `GetTemporaryRT` 按 `bufferSize` 分配
- Lighting / PostFXStack 实例字段直接带走
- 已知待补：半透明物体延迟下需单独 forward 叠绘、MRT 与 SRP Batcher 兼容性

### 延迟渲染架构的 5 条关键约束
1. 两渲染器类型不同 → pipeline 需公共基类（抽 `CameraRendererBase` 含 `Render`+`Dispose`，原 `CameraRenderer` 加 `: CameraRendererBase`）
2. GBuffer RT **按帧在 `Setup` 用 `GetTemporaryRT` 按 `bufferSize` 分配**，不放构造函数
3. 复制后 `static` ID 作用域隔离不冲突（GBuffer ID 全在 Deferred 类内）
4. 共享 `.hlsl` 库（Surface/BRDF/Lighting/Shadows）直接 `#include` 复用，shader 侧只新增 GBuffer Pass + light pass 两个 shader
5. `Lighting`/`PostFXStack` 实例字段直接带走，`PostFXStack` 不变（输出目标仍是 colorAttachmentId），`Lighting.Setup` 传 `useLightsPerObject=false`

### 帧缓冲与拷贝
- `CopyTexture` 优先，WebGL 2.0 回退到 Draw shader
- Gizmos 深度修复：DrawGizmos 前拷贝深度到 CameraTarget
- Tile-based GPU：分屏时 camera.rect == fullViewRect ? DontCare : Load

### 反射探针
- CameraType.Reflection 单独控制 copyDepthReflection / copyColorReflection

## ShaderGUI 开发记录

### 关键字手动同步
- `[Toggle(_CLIPPING)]` 等关键字不会自动同步到材质 keyword，需在 GUI 中用 `SetKeyword` 手动 Enable/Disable
- `[KeywordEnum]` 同理：`SetKeyword("_MASK_MAP_SINGLE", maskMode == 1)`
- `SetShadowCasterPass()` 根据 `_Shadows` 值调用 `m.SetShaderPassEnabled("ShadowCaster", enabled)`

### BakedEmission
- `editor.LightmapEmissionProperty()` 绘制 GI 下拉菜单（None/Baked/Realtime）
- 修改后清除 `EmissiveIsBlack` 标记，否则 Unity 跳过 emission 烘焙

## 已知问题
- 旧 `.mat` 文件（如 Catlike_Scene8）仍带失效的 `_MASK_MAP` 关键字与 `_MaskMapToggle` 属性，需在新 GUI 下重新设置 Mask 模式
- Shadowmask 在 deferred 下不支持
- Meta Pass 中 Detail UV 未传入（c.detailUV = 0.0）
