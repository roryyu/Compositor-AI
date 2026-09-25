# Compositor AI 功能详细设计

> 版本 v1.0 · 2026-09-24 · 状态:待评审
> 目标:为 Compositor 增加三个 AI 能力——①可配置的多模态模型(识图/生图分离);②自然语言生图并插入图层;③自然语言驱动编辑器自动绘图。

---

## 1. 现状调研结论(设计的落点)

基于对代码的通读,AI 功能可完全挂在现有机制上,无需改动核心架构:

| 现有机制 | 位置 | AI 功能如何使用 |
|---|---|---|
| 顶层菜单 | `CompositorApp.swift` 的 `CommandMenu(...)` | 新增 `CommandMenu("AI")` |
| 插入图层 | `EditorSession.insert(_ asset: ImportedImage, centeredAt:)` | 生图结果直接构造 `ImportedImage` 插入,自动进历史、自动设为活动图层 |
| 导入图像模型 | `ImportedImage(image: CGImage, thumbnail: CGImage, name: String)`,缩略图用 `PixelAdjust.thumbnail(of:)` | 生成图(CGImage)直接构造,无需落盘 |
| 撤销/历史 | `beginEdit("名称") / endEdit()` 快照整个 `CanvasDocument` | AI 的每一步变更各包一对 begin/end,天然可逐步撤销 |
| 忙碌互斥 | `isProjectBusy / showsBusy / waitForProjectAccess()` | AI 网络请求与批量操作期间复用该机制,防止并发编辑 |
| 图层模型 | `ImageLayer`(asset/transform/opacity/blendMode/mask/adjustment/shape/text/effects),`CanvasDocument.layers` 自底向上 | Agent 工具目录直接映射这些字段 |
| 调整/滤镜 | `AdjustmentKind`(hsv/levels/curves/exposure/gradientMap/grain/addNoise/gaussianBlur/motionBlur/invert/blackWhite/colorBalance)、`FilterKind`(vignette/bloomGlow/tonalContrast/lensCorrection/cameraRaw/removeBackground/contentAwareFill…) | Agent 的 `apply_adjustment` / `apply_filter` 工具按枚举分发 |
| 选区/绘制 | `selectAll/invertSelection/promptSelectionAmount(.feather…)`,`BrushSettings`(diameter/hardness/opacity/color/smoothing),形状与文字图层(`shape`/`text`) | Agent 绘图工具复用同一路径 |
| 本地 AI 先例 | `SubjectRemoval`(Vision `VNGenerateForegroundInstanceMaskRequest`) | 证明 AI 能力可无缝融入;Agent 的 `select_subject` 直接复用 |
| 尺寸限制 | `DocumentLimits.maxSide = 30000`,`documentPixelBudget`(按机器内存) | 生图结果超限时等比缩放后再插入 |
| 设置存储 | `UserDefaults`/`@AppStorage` 既有;自定义窗口先例 `ShortcutSettings.shared.show()` | 模型参数存 UserDefaults,**API Key 存 Keychain** |
| 网络 | 沙盒 entitlements 已含 `com.apple.security.network.client` | 无需改 Info.plist/entitlements |

沙盒已开启、网络客户端权限已具备,Keychain 在沙盒内可用。

---

## 2. 总体架构

四层结构,依赖自上而下,服务层与 UI 解耦(便于测试):

```
┌────────────────────────────────────────────────────────────┐
│ UI 层   CommandMenu("AI")                                  │
│         AISettingsSheet · GenerateImageSheet · AIPanel     │
├────────────────────────────────────────────────────────────┤
│ 服务层  VisionService(识图/分析)                            │
│         ImageGenerationService(生图)                        │
│         EditAgent(编辑代理:function-calling 循环)           │
├────────────────────────────────────────────────────────────┤
│ 传输层  ChatTransport:OpenAI 兼容 /chat/completions        │
│         (messages + tools + 可选 SSE 流式)                  │
│         ImageGenAdapter 协议:openai-images / ark-seedream  │
│         / dashscope-wanx / gemini                          │
├────────────────────────────────────────────────────────────┤
│ 基础层  KeychainStore · AISettingsStore · ImageCodec        │
│         (压缩/缩放/编解码, DocumentLimits 检查)             │
└────────────────────────────────────────────────────────────┘
```

**协议选型说明**:对话/识图统一走 **OpenAI 兼容 `/chat/completions`**(含 `tools` 参数),可覆盖 OpenAI、DeepSeek、通义 compatible-mode、智谱、Moonshot、火山方舟、Gemini 兼容端点、Ollama 等绝大多数多模态模型,天然满足"任意多模态模型都能配置"。生图没有统一标准,故用适配器协议隔离各家差异。

---

## 3. 模块详细设计

### 3.1 配置模块(AISettings)

两个独立的 Provider 配置,各自完整的 baseURL/apiKey/model:

```swift
struct AIProviderConfig: Codable, Equatable {
    var baseURL: String        // 如 https://api.openai.com/v1
    var model: String          // 如 gpt-4o / doubao-seedream-4-0
    var preset: ProviderPreset // 预设,决定请求细节与占位提示
    // apiKey 不在此结构内,只存 Keychain
}

enum AIConfigRole: String { case vision, image }  // 识图(chat) 与 生图
```

- **识图(Vision)**:`AIProviderConfig(role: .vision)`,即 chat 端点;**编辑代理(EditAgent)复用此配置**——它本质也是 chat(带 tools),多模态模型还能看画布截图,一个配置两用,符合"识图和生图分开"的要求。
- **生图(Image)**:`AIProviderConfig(role: .image)`,走生图适配器。

**Provider 预设表**(设置页下拉选择后自动填 baseURL,模型名可改):

| Preset | baseURL 默认值 | 生图适配器 | 备注 |
|---|---|---|---|
| OpenAI | `https://api.openai.com/v1` | openai-images | gpt-image-1 |
| DeepSeek | `https://api.deepseek.com/v1` | — | 仅识图/Agent |
| 通义千问 DashScope | `https://dashscope.aliyuncs.com/compatible-mode/v1` | dashscope-wanx | qwen-vl / wanx |
| 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4` | — | glm-4v |
| 月之暗面 Moonshot | `https://api.moonshot.cn/v1` | — | |
| 火山方舟 Ark | `https://ark.cn-beijing.volces.com/api/v3` | ark-seedream | Doubao VL / Seedream |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | gemini | OpenAI 兼容层 |
| Ollama(本地) | `http://localhost:11434/v1` | — | apiKey 可为空 |
| Custom | 空 | openai-images | 任意 OpenAI 兼容服务 |

**存储**:
- `UserDefaults`:`ai.vision.baseURL`、`ai.vision.model`、`ai.vision.preset`、`ai.image.*` 同理。
- **Keychain**:`kSecClassGenericPassword`,service = `com.wonderassembly.compositor.ai`,account = `ai.vision.apiKey` / `ai.image.apiKey`。Key 永不进 UserDefaults、永不打日志。
- 读写封装为 `KeychainStore` 协议 + 真实实现 + 测试用内存实现。

**设置界面**(`AISettingsSheet`,仿 `ShortcutSettings.shared.show()` 的自建窗口模式,与工程风格一致):
- 两个分栏:"Vision / Chat"(识图与编辑代理)与"Image Generation"(生图)。
- 每栏:Preset 下拉、baseURL 输入、model 输入、apiKey 安全输入(显示 ●,可点击眼睛切换)、"Test Connection"按钮(vision 发一条最小 chat 请求;image 调一次最小生图或仅校验 401 前置)。
- 校验:URL 合法、model 非空;Ollama 允许空 key。

### 3.2 传输层

**ChatTransport**(OpenAI 兼容):

```swift
struct ChatRequest {
    var messages: [ChatMessage]          // system / user / assistant / tool
    var tools: [ToolDefinition]?         // name + JSON Schema parameters
    var temperature: Double?
    var stream: Bool                     // M4 首版 false,M5 起 true
}
struct ChatMessage {
    enum Content { case text(String)
                   case parts([Part]) }  // Part = .text | .imageBase64(mime, data)
    var role: Role; var content: Content
    var toolCalls: [ToolCall]?           // assistant 返回
    var toolCallID: String?              // tool 角色回填
}
protocol ChatTransport { func send(_ request: ChatRequest) async throws -> ChatResponse }
```

- `OpenAICompatTransport`:URLSession async/await,POST `{baseURL}/chat/completions`。
- 识图传图:图像缩放到最长边 ≤ 1568px、JPEG 0.85(在 `ImageCodec` 中),转 base64 data URI 放入 `image_url`。
- 错误统一映射 `AIError`;429/5xx 指数退避重试(≤2 次,尊重 `Retry-After`);支持 Task 取消。
- 超时:chat 120s,生图 300s。

**ImageGenerationAdapter** 协议:

```swift
struct ImageGenRequest { var prompt: String; var width: Int; var height: Int; var count: Int }
struct ImageGenResult { var data: Data }   // PNG/JPEG 字节,统一出口

protocol ImageGenAdapter { func generate(_ request: ImageGenRequest) async throws -> [ImageGenResult] }
```

首批四个适配器:
1. **OpenAIImagesAdapter**:`POST /images/generations`,`size` 归一为 `1024x1024` 等就近合法值,`b64_json` 响应。
2. **ArkSeedreamAdapter**(火山方舟):`POST /api/v3/images/generations`,响应 `data[0].url` 或 `b64_json`,url 需二次 GET 下载。
3. **DashScopeWanxAdapter**:异步两段式——`POST /services/aigc/text2image/image-synthesis` 拿 task_id,轮询 GET 直到 `SUCCEEDED` 取 url。
4. **GeminiImageAdapter**:Gemini 生图端点。

适配器内部自行处理各家参数差异,对外只暴露统一 `ImageGenRequest/Result`。

### 3.3 功能二:自然语言生图 → 插入图层

**入口**:`AI` 菜单 → "Generate Image…"(⇧⌘G,已核对该快捷键空闲)。

**流程**:

```
用户输入 prompt + 尺寸 + 张数
        │
        ▼
ImageGenerationService.generate()  ──网络/轮询──►  [Data]
        │
        ▼
ImageCodec.decode(Data) → CGImage
        │  超 DocumentLimits? → 等比缩到画布内(maxSide / pixelBudget 双检查)
        ▼
ImportedImage(image:, thumbnail: PixelAdjust.thumbnail(of:), name: "AI Image N")
        │  await session.waitForProjectAccess()
        ▼
session.insert(asset, centeredAt: nil)   ← 现有 API:居中插入、进历史、设为活动图层
```

**GenerateImageSheet UI**:
- prompt 多行输入框(可从"识图"结果一键填充,见 3.4);
- 尺寸:默认"Match Canvas"(取画布宽高,适配器归一到最近的合法档位),备选 1:1 / 3:2 / 2:3 / 自定义;
- 张数 1–4,逐张插入图层,命名 `AI Image 1..N`;
- 底部显示当前生图模型;生成中显示进度与"Cancel"(取消 = task.cancel());
- 失败在 sheet 内 alert 呈现 `AIError` 的本地化描述,画布不动。

**历史**:插入由 `session.insert` 内部的 `beginEdit("Import Image")` 覆盖;实现时将 AI 插入单独包一层 `beginEdit("AI Generate Image")` 以便历史面板语义清晰(以实现时 `insert` 的实际行为微调,若重复则直接复用)。

### 3.4 功能:识图(VisionService)

```swift
struct VisionService {
    /// 提问画布/图层:"这张图里主体在哪""配色是什么""给我一段把背景换成蓝天的生图提示词"
    func analyze(image: CGImage, question: String) async throws -> String
}
```

三个使用场景:
1. **Analyze 菜单**:"AI" 菜单 → "Analyze Canvas…" / "Analyze Active Layer…",弹小窗显示回答(可复制)。图像来源:画布用现有 `drawLiveComposite(document, in:)` 合成(与 `selectSubject` 相同路径);图层用 `layer.asset.image`。
2. **Agent 的 `analyze_image` 工具**(见 3.5),让 LLM "看见"画布。
3. **提示词辅助**:Analyze 结果窗口提供 "Use as Generate Prompt" 按钮,把生成的提示词填进 GenerateImageSheet。

### 3.5 功能三:编辑代理(EditAgent)

**核心机制**:LLM function-calling 循环(ReAct)。Agent 拿到画布状态与工具目录,模型决定调用哪个编辑器功能,本地执行后把观察结果回传,循环直到模型调用 `finish`。

```
用户指令("画一个橙色渐变背景,中间放一个白色圆")
        │
        ▼
┌── Agent 循环(最多 maxSteps=16 轮)────────────────────────┐
│ 1. 组装 messages:系统提示 + 画布状态快照 + 历史对话/观察   │
│ 2. ChatTransport.send(tools: 工具目录)                     │
│ 3. 模型返回 tool_calls → AIToolDispatcher 在主线程逐个执行  │
│    每个变更操作包 beginEdit("AI: <工具名>")/endEdit        │
│ 4. 观察结果(JSON:成功/失败 + 新状态摘要)追加进 messages    │
│ 5. 模型返回 finish(summary) 或超步数 → 退出                │
└────────────────────────────────────────────────────────────┘
```

**系统提示词要点**(随请求注入):
- 角色与目标;坐标系约定:文档像素、以 `LayerTransform.origin` 为准(与工程内部 `BrushRaster.pixelToDocument` 一致,实现时对齐原点方向);
- 每轮注入的**画布状态快照** `CanvasStateSnapshot`:画布宽高、图层树(id/name/visible/opacity/blendMode/bounds/isGroup/hasMask/adjustmentKind)、activeLayerID、选区 bounds、当前工具。id 用短哈希(前 8 位)以省 token,Dispatcher 负责还原完整 UUID。

**工具目录**(按实施批次,签名示意):

批 1 —— 状态与图层(安全,先交付):
| 工具 | 映射的现有能力 |
|---|---|
| `get_canvas_state()` | `CanvasStateSnapshot`(只读) |
| `analyze_image(target, question)` | VisionService(只读) |
| `add_blank_layer(name)` | `session.addBlankLayer()` |
| `add_image_layer(prompt|image_ref, name)` | 3.3 生图路径 / `session.insert` |
| `duplicate_layer(id)` | `session.layerViaCopy()` |
| `delete_layer(id)` | `session.deleteLayerOrMask()` |
| `set_layer_properties(id, opacity?, blendMode?, visible?, name?)` | 直接改 `ImageLayer` 字段 |
| `reorder_layer(id, direction)` | `session.moveActiveLayer(by:)` 语义 |
| `group_layers(ids)` / `merge_layers(ids?)` | `groupSelectedLayers()` / `mergeLayers()` |
| `flip(target, axis)` | `flipCanvas/flipLayers(horizontally:)` |
| `transform_layer(id, dx, dy, scale?, rotation?)` | `LayerTransform` 修改 |
| `undo()` | `session.undo()` |

批 2 —— 绘制与调整:
| 工具 | 映射 |
|---|---|
| `fill_layer(color)` / `fill_selection(color)` | `fillSelection(with:)`(前景色路径,先设色) |
| `draw_stroke(points, diameter, hardness, opacity, color)` | `BrushStroke` 提交路径(程序化走线,Shift 直线同理) |
| `draw_shape(kind: rect/ellipse, rect, fill?, stroke?, color)` | Shape 工具的图层 `shape` 字段 |
| `add_text(text, point, fontSize, color)` | `TypeTool` 的 text 图层 |
| `draw_gradient(kind, from, to, rect)` | Gradient 工具路径 |
| `apply_adjustment(layer, kind, params)` | `AdjustmentKind` + 各 Settings 结构(hsv/levels/curves/exposure/blur/noise/invert…) |
| `apply_filter(layer, kind, params)` | `FilterKind`(vignette/bloom/tonalContrast/removeBackground…) |

批 3 —— 选区、画布与联动:
| 工具 | 映射 |
|---|---|
| `set_selection(shape: all/rect/ellipse, rect?, feather?)` | `selectAll` + 选区 API / `promptSelectionAmount(.feather)` |
| `modify_selection(expand/contract/invert/none)` | 同上系列 |
| `select_subject()` | 现有 Vision `selectSubject()` |
| `crop(rect)` / `resize_canvas(w,h)` / `resize_image(w,h)` / `trim()` | Crop / CanvasSize / ImageSize / Trim 路径 |
| `generate_image(prompt, size)` | 内部走 3.3,把能力闭环给 Agent("给海报加一张 AI 生成的云背景") |

**安全与一致性**:
- Agent 运行期置 `isAgentRunning`(复用 `isProjectBusy` 展示与 `canStartProjectOperation` 拦截),工具逐个串行执行,与用户操作天然互斥;
- 每步 `beginEdit`/`endEdit` → 历史面板可见每一步,可逐步 Undo;失败的工具返回错误 JSON,模型可自纠错;
- `maxSteps` 上限 + 总 token 粗算上限,防失控;
- API Key 不出现在任何日志;请求日志仅 DEBUG 构建且脱敏。

**AIPanel UI**(仿现有 `FloatingPanel` 风格):
- 顶部:模型名;输入框 + "Run" 按钮;
- 中部:步骤时间线(每步:工具名 + 参数摘要 + ✓/✗ + 耗时),运行中实时追加;
- 底部:"Stop"(取消当前 Task,已执行的步骤保留在历史可撤销)、结果 summary 气泡。

### 3.6 新增/修改文件清单

```
Compositor/AI/                          (新目录)
  AISettings.swift                      配置模型 + UserDefaults 存取 + 预设表
  KeychainStore.swift                   Keychain 读写(协议 + 实现)
  AIError.swift                         错误类型 + 本地化文案
  ChatTransport.swift                   OpenAI 兼容 chat 客户端(含 tools/SSE)
  VisionService.swift                   识图
  ImageGenerationService.swift          生图编排(选适配器/并发/取消)
  ImageGenerationAdapters.swift         openai-images / ark / dashscope / gemini
  EditAgent.swift                       function-calling 循环
  AIToolCatalog.swift                   工具 JSON Schema 定义
  AIToolDispatcher.swift                工具 → EditorSession 分发
  CanvasStateSnapshot.swift             画布状态序列化
Compositor/UI/
  AISettingsSheet.swift  GenerateImageSheet.swift  AIPanel.swift   (新增)
CompositorTests/
  AIKeychainTests.swift  AITransportTests.swift(mock URLProtocol)
  AIAdapterDecodingTests.swift  AIToolDispatcherTests.swift  (新增)
修改:
  CompositorApp.swift                   +CommandMenu("AI")
  Compositor.xcodeproj                  注册新文件
```

### 3.7 错误处理与边界

| 错误 | 表现 |
|---|---|
| 401/403 | "API Key 无效或无权限",设置页 Test Connection 同样可暴露 |
| 429/5xx | 自动退避重试 ≤2 次,仍失败则报"服务繁忙" |
| 网络不可达/超时 | 中文描述 + 建议检查 baseURL |
| 响应解码失败 | 报"模型返回格式异常",附 provider 原始 message |
| 生图超限 | 自动等比缩放到 DocumentLimits 内再插入,并在结果里注明 |
| Agent 步数超限 | 结束循环,输出已完成步骤摘要 |
| 用户取消 | Task.cancel,网络请求中断,画布保持已落盘状态(已执行步骤在历史中可撤销) |

### 3.8 测试策略

- **Transport**:协议注入 + `URLProtocol` mock,验证请求体结构(tools/messages/base64)、重试、错误映射;
- **适配器解码**:各 provider 的响应 fixture JSON(仿 `PSDFixture` 模式)做解码单测,含 Ark 的 url 下载与 DashScope 的轮询状态机;
- **Dispatcher**:参照现有 `CompositorTests` 构造 `EditorSession` 的方式,逐工具断言画布副作用与 `history` 可撤销;
- **Snapshot**:图层树序列化/还原 roundtrip;
- **Keychain**:内存实现测试存取逻辑(真实 Keychain 不进 CI)。

### 3.9 分期实施计划

| 里程碑 | 内容 | 可交付 |
|---|---|---|
| **M1 基座** | KeychainStore / AISettings / 预设表 / AISettingsSheet / ChatTransport + Test Connection | 设置可用,任意 OpenAI 兼容模型可连通 |
| **M2 生图** | ImageGenerationService + openai-images 适配器(先) + GenerateImageSheet + 插入图层 | 需求②闭环 |
| **M3 识图** | VisionService + Analyze 菜单 + 提示词辅助按钮 | 画布/图层可被描述 |
| **M4 Agent MVP** | EditAgent 循环(非流式)+ 批 1 工具 + AIPanel + get_canvas_state | 需求③最小闭环 |
| **M5 Agent 扩展** | 批 2/3 工具 + ark/dashscope 生图适配器 + 流式进度 + `generate_image` 联动 | Agent 能画能改 |
| **M6 打磨** | 提示词预设库、历史面板语义("AI: …")、错误文案、测试补全、README | 发布质量 |

依赖关系:M1 → M2/M3 → M4 → M5 → M6;M2 与 M3 可并行。

---

## 4. 关键设计决策(Open Questions,待确认)

1. **识图与 Agent 共用一个 chat 配置**:是(本设计)。若将来需要"Agent 用便宜文本模型 + 识图用多模态模型",可再加第三个 role,配置结构已预留扩展。
2. **UI 文案语言**:跟随工程现状用英文("AI"、"Generate Image…"),还是中文?本设计按英文。
3. **Agent 首版是否流式**:非流式(M4),M5 升级 SSE;非流式实现简单且现有忙等机制够用。
4. **生图首批适配器**:openai-images(最通用)先行,ark/dashscope 紧随;gemini 视需求。
5. **Agent 危险操作**(删层/裁剪/改画布尺寸)是否需确认弹窗:首版不弹,依赖逐步 Undo 与 Stop;若测试体验不佳再加白名单确认。
