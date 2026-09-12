# MEMORY（长期记忆）

## 项目
- Unity **2023.2.20f1c1**，自定义 SRP「**Argonara RP**」（Catlike 风格教学向管线），代码在 `Assets/ArgonaraRP`；
  管线资产：`Assets/Settings/Argonara Render Pipeline Asset.asset`；阴影核心：`Runtime/Shadows.cs`、`ShaderLibrary/Shadows.hlsl`。
- **用户会同时用别的 AI 改同一批文件**：我改过的东西被回退/覆盖过多次。**动手前必须先读当前文件状态**，不要凭上一轮的记忆直接改。
- 用户能看 git（GitHub Desktop 的前端就是 `git diff`，我能读同一份数据）；Rider 的 Local History 存在 %APPDATA% 下，读不到。

## 用户偏好
- **回答要短**：先给结论，再一两句理由；不要长清单、不要长篇分析（多次要求"简单说"）。
- 改代码偏好**最少、非破坏性**的改动；改完要自检（lint/编译）并说明**怎么验证**。
- **严格按用户列举的范围改**：顺带发现的"死字段/死代码/过时注释"要先**报告并等确认**，不要自己顺手删（2026-09-11 我顺手删了因此变成只写字段的
  `ShadowedDirectionalLight.nearPlaneOffset`，被质问"不是没让你这样干吗"）。
- 提"咋回事"这类问题时：先解释原因 + 给方案，再问是否动手；一旦说"改吧"就直接改完。
- **不要什么都往 memory 里写**：只记有跨会话价值的结论/约定，别把每轮的清单细节、分析过程搬进去（用户明确提过）。
- **不要写自定义 `PropertyDrawer`**（加过两次都被否："改的太多""别加 drawer 了"）。要在 Inspector 里分组，就用 `[System.Serializable]` 嵌套结构体；
  字段归类重命名时**必须同步改管线资产 `.asset` 里的键**（否则用户调好的值会被重置）。

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
