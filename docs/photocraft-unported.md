# PhotoCraft 未移植功能清单

> 状态快照 · 2026-10 · 供选择下一批开发用
> 已完成部分见 [README](../README.md)「调整与滤镜」与 [ai-design.md](ai-design.md)：Tier 1（AI/MCP 工具面）与 Tier 2（7 调整 + 11 滤镜）全部落地并通过测试。
> **第二批（#1–#6）已全部落地并通过测试**：Color Lookup、Displace、Channel Mixer 单色补全、Dodge/Burn/Sponge、Mixer Brush（Mix 模式）、钢笔/路径图层。#7 用户裁定不做；#8/#9 已被 AI/MCP 工具面覆盖，不做。

## 总览

| # | 功能 | 类别 | 规模 | 状态 |
|---|---|---|---|---|
| 1 | Color Lookup（.cube LUT） | 调整/滤镜 | 中 | ✅ 已完成 |
| 2 | Displace 置换滤镜 | 滤镜 | 中 | ✅ 已完成 |
| 3 | Channel Mixer 单色模式补全 | 调整 | 小 | ✅ 已完成 |
| 4 | Dodge / Burn / Sponge 修图工具 | 绘制工具 | 中 | ✅ 已完成 |
| 5 | Mixer Brush（湿边混合） | 绘制工具 | 大 | ✅ 已完成（Mix 模式，实用混色近似） |
| 6 | 钢笔 / 矢量路径 | 工具 + 文档模型 | 大 | ✅ 已完成（路径图层，非 PSD 矢量） |
| 7 | 笔刷动力学（压感/倾角/速度驱动） | 绘制引擎 | 大 | ❌ 用户裁定不做 |
| 8 | 命令面板（Command Palette） | UI | 中 | ❌ AI/MCP 已覆盖，不做 |
| 9 | Actions / 批处理自动化 | 架构 | 大 | ❌ AI/MCP 已覆盖，不做 |

---

## 1. Color Lookup（.cube LUT 调色）

> ✅ **已完成**：新增 `Document/CubeLUT.swift`（`CubeLUT` 解析 `.cube` 三维表 + `ColorLookupSettings`），双管线接入 `FilterKind.colorLookup` / `AdjustmentKind.colorLookup`；LUT 数据内嵌进 settings 随文档持久化（同 PSD 内嵌做法），面板提供「Choose…」选 `.cube` 文件 + Intensity 滑杆；AI/MCP 不暴露（需文件输入）。测试 `CubeLUTTests`。

- **PhotoCraft 来源**：调整栈里的 Color Lookup，加载 `.cube` 三维查表文件。
- **Compositor 现状**：完全没有；Core Image 有现成的 `CIColorLookup` / `CIColorCube`，缺的是管线外的东西。
- **需要的工作**：
  - `.cube` 文件解析器（DIMENSION / LUT_3D_SIZE / 三元组，→ `CIColorCube` 数据或 `CIImage` LUT）；
  - LUT 文件的选择与存放（随工程 bundle 还是全局 LUT 库，需要决策）；
  - 走双管线惯用法：`FilterKind` + `AdjustmentKind` 各加一 case，settings 存 LUT 的引用而非数据（Codable 设计是主要难点——旧工程里 LUT 文件被移走后的失效兜底）。
- **规模**：中。解析 + 接线约等于 PhotoAdjustments 里最复杂一项的量。

## 2. Displace 置换滤镜

> ✅ **已完成**：`FilterKind.displace`（仅滤镜，不进 AdjustmentKind，避开持久化第二输入）；底层滤镜是 `CIDisplacementDistortion`（非 `CIDisplacementMap`，后者在 macOS 不存在）。位移图取自文档内其它栅格图层，面板提供图层 Picker + Scale 滑杆（R=X、G=Y、中性灰=不动）；AI/MCP 不暴露。测试 `DisplaceTests`。

- **PhotoCraft 来源**：Distort 族的 Displace（`CIDisplacementMap`）。
- **为什么跳过**：它需要第二张图（位移图）作为输入，不属于「单参数滤镜」，UI 与序列化都要为这个额外输入设计。
- **需要的工作**：位移图来源（当前活动图层之外的一个图层？弹窗选文件？）、`CIDisplacementMap` 的 scale/x/y 参数面板、`PixelFilter.run` 里取第二输入的通路。
- **规模**：中。核心是交互设计而不是算法。

## 3. Channel Mixer 单色模式补全

> ✅ **已完成**：`ChannelMixerSettings` 新增 red/green/blueConstant（作 `CIColorMatrix` 的 bias 向量）；FilterSheet 每组尾部加 Constant 滑杆，Monochrome 开启时补 PS 经验权重（red 40/green 40/blue 20）。`AdjustmentLayerTests` 扩断言。

- **现状（已知简化）**：勾选 Monochrome 时用 Red 行同时驱动三个输出通道；Photoshop 的语义是三行各自加权 + 输出层色阶修正行，且默认给一组经验权重。
- **需要的工作**：monochrome 时把三行按 luminance 权重合成，或补 Output 色阶行；改 [PhotoAdjustments.swift](../Compositor/Document/PhotoAdjustments.swift) 的 `ChannelMixerSettings` 与 FilterSheet 对应面板，纯局部改动。
- **规模**：小。一次改动 + 两个既有测试文件扩断言即可。

## 4. Dodge / Burn / Sponge（减淡 / 加深 / 海绵）

> ✅ **已完成**：`SmudgeLiquify.swift` 的 `BrushToolMode` 加 dodge/burn/sponge，新增 `ToneStroke`（结构照抄 `WarpStroke`：逐 dab、weight 硬度衰减、finish 时一步撤销）；按亮度分 Shadows/Midtones/Highlights 加权；强度复用 `brushSettings.opacity`（sponge 为 Flow）。测试 `ToneStrokeTests`。

- **PhotoCraft 来源**：修图工具族。
- **Compositor 现状**：已有 Blur tool 这类「笔刷路径作用于像素」的先例（`Blur tool, on pixels or masks`），框架可完整复用。
- **需要的工作**：三个 tool case（曝光乘法/色饱和度调整，按笔刷落点局部作用 + range 保护高光/阴影/中间调），工具枚举、图标、header 参数（Exposure / Range / Size / Hardness / Flow）。
- **规模**：中偏小。与 Tier 2 同级别的接线量，无新文档模型。

## 5. Mixer Brush（混色画笔）

> ✅ **已完成（用户裁定的实用混色近似）**：不重写笔刷引擎，作为 Smear 工具（`tool == .blur`）的第 4 个 mode `mix`，完全复用 `WarpStroke` 的 carried 机制；`Wet`/`Mix` 两条滑杆，起笔载入前景色，逐 dab `target=carried·(1−m)+under·m`、沿途按 wet 吸色。单色 load 近似（无多色湿颜料库存）。测试 `MixerStrokeTests`。

- **PhotoCraft 来源**：湿边、载色、混色的油画式笔刷。
- **为什么没做**：需要重做笔刷引擎——每笔画携带「湿颜料库存」、笔尖颜色采样、混色累积；Compositor 现在的 `BrushSettings` 是干模式单一颜色，改动贯穿绘制事件、每帧合成与撤销快照，性能还要过 Metal 路径。
- **规模**：大。独立项目级。

## 6. 钢笔 / 矢量路径（Pen & Paths）

> ✅ **已完成（路径图层，非 PSD 矢量）**：新增 `Document/PenTool.swift`，完全镜像 `LayerShape` 模式——`PathAnchor`/`LayerPathStyle`（单位坐标 + `cgPath`）/`LayerPath`（参数化样式 + 栅格图像，像素被改即退化为普通层）；支持填充/描边、贝塞尔手柄、锚点再编辑、路径→选区、栅格化。工具键 P，UI 见 `UI/PenControls.swift`。不含自由钢笔与 PSD 路径导入导出。测试 `PenToolTests`。

- **PhotoCraft 来源**：矢量图层与路径编辑（贝塞尔锚点、方向杆）。
- **为什么没做**：Compositor 的 Shape/Text 图层已经是「参数化可编辑」而非真矢量：引入 Paths 需要新图层类型、命中测试、锚点编辑 UI、与栅格互转（rasterize）、PSD 导入导出的矢量语义——文档模型和撤销快照都要动。
- **规模**：大。动的是架构，不是功能点。

## 7. 笔刷动力学（Brush Dynamics）

> ❌ **用户裁定不做。**

- **PhotoCraft 来源**：压感/倾角/速度/随机驱动大小、不透明度、流向。
- **为什么没做**：依赖输入设备事件通路（macOS 上 Pencil/Wacom 事件），且参数曲线系统本身是个小框架。
- **规模**：大。若只做压感驱动大小/不透明度，可切一个「小动力学」子集先行。

## 8. 命令面板（Command Palette）

> ❌ **不做：AI/MCP 工具面已覆盖「搜索并执行命令」的需求。**

- **PhotoCraft 来源**：⌘K 面板，搜索并执行所有菜单命令。
- **需要的工作**：纯 UI——把 `CommandMenu` 动作收集成可搜索列表（Compositor 菜单动作已有 `configuredKeyboardShortcut` 元信息，等于现成的命令注册表），加一个 ⌘K 浮层。不碰业务逻辑。
- **规模**：中。风险低，独立可做，适合排在两批功能之间。

## 9. Actions / 批处理（动作录制）

> ❌ **不做：`AIToolDispatcher` 的语义化操作集合已覆盖「录制/回放操作序列」的需求。**

- **PhotoCraft 来源**：操作序列录制与回放、droplet 批处理。
- **为什么没做**：需要把每步编辑变成可序列化、可重放的操作记录——Compositor 的撤销历史是整文档快照（`beginEdit/endEdit`），不是操作日志，做 Actions 等于再加一层「操作语义」架构。
- **规模**：大。且与 AI agent 工具面（`AIToolDispatcher` 已经是语义化操作集合）需要先定边界：是给 Dispatcher 加录制器，还是另起一层。

---

## 推荐节奏

第二批（#1–#6）已全部落地并通过测试（`build-for-testing` + 定向 `test-without-building`：CubeLUTTests、DisplaceTests、ToneStrokeTests、MixerStrokeTests、PenToolTests、AdjustmentLayerTests、FloatingPanelTests、FilterTests、ImageAdjustmentTests、FinishingFilterTests、AITests 全绿）。

剩余 #7/#8/#9 均已裁定不做（#7 用户裁定，#8/#9 被 AI/MCP 工具面覆盖）。PhotoCraft 未移植清单至此收敛完毕。
