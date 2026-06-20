# Project Memory (ArgonaraRP)

## 项目概述
- Unity SRP (Scriptable Render Pipeline) 项目，基于 Catlike Coding 教程构建自定义渲染管线。
- 项目路径：`d:\Unity\Unity_Projects\ArgonaraRP`
- 资源目录：`Assets\ArgonaraRP\`

## 关键架构
- `ArgonaraRenderPipeline : RenderPipeline` — 主渲染管线类（partial class，拆分运行时/编辑器文件）
- `ArgonaraRenderPipeline.Editor.cs` — 编辑器分部类，`#if UNITY_EDITOR`，含烘焙光照委托
- `CameraRenderer` — 逐相机渲染（同样 partial class 拆分）
- `Lighting.cs` — 光照设置，管理最多4方向光+64其他光，通过全局shader数组发送灯光数据到GPU
- `Shadows.cs` — 阴影管理
- ShaderLibrary：`Light.hlsl`, `Lighting.hlsl`
- Shaders：`Lit.shader`（含 ArgonaraLit/ShadowCaster/Meta 三个Pass）

## 已完成进度
- 阶段二/Catlike 第九课：烘焙光影 — 已实现光照委托，InverseSquared衰减。
- LightMode体系：Directional/Point/Spot/Rectangle 四种灯光完整支持。
