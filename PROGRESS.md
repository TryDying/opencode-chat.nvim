# 经验教训记录

> 每次遇到问题或完成重要改动后在此记录，必须附上 git commitID。
> 仅记录重要 bug 修复或重大变更；不要记录初始化、脚手架生成、纯文档补全等噪音内容。

## 2026-06-27：MVP 通信边界落地

- 问题：opencode TUI 不能被当作可靠协议层，直接向 terminal 注入文本容易受焦点、paste mode 和 TUI key handling 影响。
- 方案：第一版只用 Neovim 原生 floating terminal 承载 TUI，实际上下文注入统一走 `POST /tui/append-prompt`。
- 预防：后续扩展仍应保持 terminal 仅负责显示；与 opencode 的编辑器通信优先通过本地 HTTP/API，并用仓库内 fake bridge 测试闭环。
- commitID：a5ac440

## 2026-06-28：最小闭环必须包含原生 UI 与 headless prompt

- 问题：只把 opencode TUI 包进 terminal 的 MVP 对用户价值不足，和手动开 terminal 运行 opencode 差异很小，且没有默认 `<M-->` 快捷键会导致入口不可见。
- 方案：改为 Neovim 原生 Chat UI，后台使用 `opencode serve`，通过 `/api/session` 创建会话并用 `/api/session/:sessionID/prompt` 发送问题；默认绑定 Normal/Visual `<M-->`。
- 预防：后续定义 MVP 时必须验证“用户完成一次提问并看到回复”的闭环，而不只是验证进程能启动或上下文能被追加。
- commitID：b9e4aff

## 2026-06-28：不要把 prompt 返回体直接当 assistant 回复

- 问题：`/api/session/:sessionID/prompt` 的返回体可能是用户消息或 prompt 回显，旧解析逻辑抓取任意 `text` 字段，导致 Chat UI 把用户输入渲染成 assistant 回复。
- 方案：发送 prompt 后轮询 message history，只提取 `info.role == "assistant"` 且 `parts[].type == "text"` 的文本作为 assistant 回复。
- 预防：测试 fixture 必须模拟“prompt 接口返回用户消息、history 才包含 assistant 消息”的场景，防止再次误把用户回显当回复。
- commitID：d76d26b

## 2026-06-28：Visual 快捷键不能只依赖 `'<`/`'>` marks

- 问题：Visual 模式 Lua keymap 触发时，`'<`/`'>` marks 可能尚未写入，导致 `<M-->` 追加选区上下文时报 `visual selection marks are not available`。
- 方案：选区引用生成优先读取 `'<`/`'>`，不可用时回退到当前 Visual 起点 `v` 和光标 `.` 的行号。
- 预防：测试必须覆盖 active Visual selection 尚未落 marks 的路径，不能只用 `setpos("'<")` / `setpos("'>")` 模拟已完成选择。
- commitID：794ceac

## 2026-06-28：真实 opencode history 路径必须纳入测试

- 问题：实现只轮询 `/session/:id/message`，但真实 opencode 的 project API 使用 `/project/:projectID/session/:sessionID/message`，导致发送后只能显示空 Error。
- 方案：启动后读取 `/project` 保存 `projectID`，assistant history 读取先尝试实例路径，失败后回退到 project 路径，并让 HTTP helper 正确识别非 2xx 状态。
- 预防：fake server 必须模拟不支持的 history 路径返回 404，只在真实兼容路径返回 assistant 消息，避免理想化测试掩盖 API 路径问题。
- commitID：14662c3

## 2026-06-28：MVP 测试必须覆盖真实工作流而非示例文件

- 问题：旧测试打开 README.md 且只覆盖简单 chat happy path，无法暴露 UI 输入体验差、上下文未带源码、edit/apply 缺失和 API 主路径偏旧等问题。
- 方案：重构为消息区 + 输入区的 Chat UI，测试改用 `/tmp` sandbox 代码文件，API 优先 `/session` 与 `/session/:id/message`，并补齐读取源码、diff preview、apply/reject 闭环。
- 预防：后续每个阶段都应在 sandbox 中验证“读取代码、提问、生成修改、预览、应用”的端到端路径，避免只测命令存在或单函数成功。
- commitID：c703368

## 2026-06-28：opencode 后端编辑不应被强制改成本地 diff/apply

- 问题：插件把 `:OpencodeEdit` 设计成模型产出 diff、插件本地 apply，但真实 opencode agent 会在后端直接完成文件编辑，导致交互模型不符合预期。
- 方案：`OpencodeEdit` 改为向配置的 opencode agent 发送编辑请求并渲染 assistant 总结；测试模拟后端直接修改 sandbox 文件，并断言 `agent/model/variant` payload。
- 预防：集成已有 agent 后端时，优先尊重后端工作流；只有后端不负责写入时，才在插件层设计本地 diff/apply。
- commitID：44fcb84

## 2026-06-28：同一个 session 不能混用新旧 message API

- 问题：用新版 `/session` 创建 session 后，`/session/:id/message` 一旦失败，客户端仍盲目 fallback 到旧 `/api/session/:id/prompt`，同时空 `stderr` 会吞掉 HTTP body，导致 UI 只显示误导性 Error。
- 方案：记录 session 的 API style，消息发送只使用匹配的 API；HTTP 错误统一格式化为 `HTTP <status>: <body>`，避免空错误。
- 预防：测试必须覆盖 HTTP body 不被空 `stderr` 吞掉，并避免跨 API style fallback 掩盖真实 schema/请求错误。
- commitID：16de2e7

## 2026-06-28：新版 message API 的 model 字段是对象

- 问题：`/session/:sessionID/message` 要求 `model` 是对象，直接发送配置字符串 `deepseek/deepseek-v4-flash` 会触发 HTTP 400：`Expected object | null`。
- 方案：配置仍允许 `provider/model` 字符串，发送新版 message API 时自动转换为 `{ providerID, modelID }`；旧 API fallback 仍保留字符串格式。
- 预防：测试需断言新版 payload 的 `model.providerID` 和 `model.modelID`，避免把配置格式与 HTTP schema 混同。
- commitID：da48cde

## 2026-06-28：Chat UI 必须管理焦点、滚动和请求生命周期

- 问题：消息区只能靠鼠标聚焦、回复不会自动滚动到底部，且请求未完成时继续提交会堆叠多个 `Thinking...`，造成看似卡死。
- 方案：为消息区/输入区加入 `<Tab>` 键盘切换，渲染后自动滚动到末尾，新增 `<C-c>`/`:OpencodeCancel`，并在请求处理中阻止重复提交。
- 预防：交互测试必须覆盖 pane focus、auto-scroll、busy guard 和 cancel，不只验证 assistant 文本是否出现。
- commitID：bc1b935

## 2026-06-28：取消与会话配置必须遵循 opencode 后端语义

- 问题：取消只停止本地 curl/轮询并由 UI 伪造 `Cancelled`，没有通知 opencode 后端；同时 `agent/model/variant` 被放进每条 message，而实际更应属于 session 创建配置。
- 方案：取消改为调用 `POST /session/:sessionID/abort`，UI 在 abort 成功后显示 `Cancelled by opencode.`；`agent/model/variant` 改为随 `POST /session` 发送，普通 message 只发送 prompt parts。
- 预防：测试必须断言 abort endpoint 被调用、单次取消只渲染一条取消状态、session create payload 含配置且 message payload 不重复配置。
- commitID：86a3c94

## 2026-06-28：abort 后不能复用已取消 session

- 问题：`POST /session/:sessionID/abort` 后继续复用同一 session，后续请求会立即得到 `MessageAbortedError`；当时对 model 字段层级仍未完全确认。
- 方案：abort 成功后清空当前 `session_id/api_style`，下一次请求重新创建 session。
- 预防：测试必须断言 cancel 后下一次请求会新建 session；model 字段 schema 需以真实 `/doc` 为准。
- commitID：6287582

## 2026-06-28：session 与 message 的 model schema 不同

- 问题：真实 `/doc` 显示 session 创建和 message 请求都可携带模型配置，但字段不同；只在 session 创建传配置会导致真实 message 返回空历史 `HTTP 200: []`。
- 方案：session 创建使用 `{ providerID, id, variant }`，message 请求使用 `{ providerID, modelID }` 并带顶层 `agent` / `variant`。
- 预防：fake server 必须在 message 缺少 `agent/model/variant` 时返回空数组，测试必须覆盖这一路径，避免再次把配置层级误判为只属于 session。
- commitID：8211d99

## 2026-06-29：模型与 variant 选择需要按 provider 建模

- 问题：把可选模型写成扁平 `provider/model:variant` 会把 variant 误绑定到模型展示维度，无法表达不同 provider 的 variant 集合，也不利于后续手动切换 variant。
- 方案：配置改为 provider 分组白名单：provider 定义 `variants`，model 定义 `default_variant`；新增 session/model/variant picker，新建 session 只创建后端 session 而不重启 server。
- 预防：测试必须覆盖 provider 分组 model picker、当前 provider variant picker、切模型重置默认 variant、手动切 variant 后 payload 生效，以及新建 session 不重启 server。
- commitID：96b1551

## 2026-06-29：session 列表不能直接展示全局 `/session`

- 问题：`GET /session` 返回全局 session，直接渲染会混入其它 workspace、subagent 或 runner 会话；同时手写 picker 生命周期独立，隐藏 Chat UI 后选择器仍残留，消息区也可能被 insert 状态污染。
- 方案：session 列表优先使用 `/project/:projectID/session`，fallback `/session` 时按 `projectID` 或归一化 `directory` 过滤；picker 优先使用 `nui.menu`，Chat hide 时统一关闭 picker，消息区聚焦显式退出 insert。
- 预防：测试必须模拟外部 project session 并断言被过滤，同时覆盖 hide 关闭 picker、message pane 不进入 insert 模式。
- commitID：de6a8e9

## 2026-06-29：主 Chat UI 更适合右侧 split panel

- 问题：把 toolbar 放进滚动消息 buffer 会在消息变多后消失；floating 主界面容易遮挡编辑区，也难以固定 status/input 区域。
- 方案：主 Chat UI 改为右侧 40% split panel，并拆成固定 toolbar、滚动 message、固定 status 和 input 窗口；请求中显示 Thinking/Streaming 状态，并尝试订阅 `/event/subscribe` SSE 增量刷新。
- 预防：测试必须断言主消息区是普通 split 而非 float、toolbar/status window 存在、panel 宽度受配置约束，并保留 SSE 不可用时的非流式 fallback。
- commitID：7731ccf

## 2026-06-29：主面板入口应优先键盘且可配置

- 问题：主面板 toolbar/鼠标按钮会引入额外 pane 标题和布局噪音；硬编码全局快捷键也会和用户现有映射冲突。
- 方案：移除主 UI toolbar，只保留 message/input/status；全局快捷键改为用户通过 `keymaps` 显式配置，variant 推荐 `<leader>Xt`，并新增当前 session 重命名入口。
- 预防：测试必须断言 toolbar window 不存在、status 在 input 下方、旧 `<leader>Xv` 不再注册、新 `<leader>Xt` / `<leader>Xr` 可配置，并覆盖 `PATCH /session/:id` 重命名。
- commitID：166e3cc

## 2026-06-29：Toggle 应优先恢复焦点而不是直接隐藏

- 问题：右侧 panel 失焦后再次触发 toggle 会直接隐藏，用户想回到 Chat 输入区时反而要重新打开；同时 pane 继承 winbar 会在首行上方留下空白行，消息区可用高度也缺少明确配置。
- 方案：toggle 改为面板隐藏时打开、面板可见但失焦时聚焦输入区、焦点在 Chat 内时隐藏；panel window 显式清空 winbar/statusline，并增加 `ui.height` 与可选 `ui.message_height`。
- 预防：测试必须断言 pane winbar 为空、toggle 失焦后聚焦 input、`ui.width/ui.height/ui.message_height` 配置存在且稳定。
- commitID：3c13fb5

## 2026-06-29：Visual 追加上下文后必须退出 Visual 模式

- 问题：Visual 模式触发 `<M-->` 追加选区并聚焦 Chat 输入区后，Neovim 仍停留在 Visual 状态，用户需要手动按 `<Esc>` 才能继续输入对话。
- 方案：在 Chat `show`、`focus_input`、`focus_messages` 等聚焦入口统一检测 Visual/Select 模式并发送 `<Esc>`，再切换到目标 pane。
- 预防：测试必须覆盖 active visual selection 追加上下文后，焦点进入 input pane 且当前模式不再是 Visual。
- commitID：2a62bc7

## 2026-06-29：Active Visual 选区必须优先于旧 marks

- 问题：连续 Visual 追加上下文时，第二次可能重复追加上一次的 `'<`/`'>` 范围，第三次才拿到新范围，因为 active Visual 选区尚未写回 marks。
- 方案：`visual_line_range` 在当前仍处于 Visual/Select 模式时优先读取 `getpos("v")` 与光标位置，仅非活动选区时回退到 `'<`/`'>`。
- 预防：测试必须覆盖旧 marks 为 L3-L5、当前 active Visual 为 L8-L8 时，最终引用应为 L8-L8。
- commitID：4d698e4

## 2026-06-29：Context 追加应可去重、可删除且不抢焦点

- 问题：上下文只能追加不能删除，重复追加会污染下一次 prompt；Visual 追加还会把焦点抢到 Chat，打断继续阅读/选择代码的流程。
- 方案：新增统一 `append_context` 入口，Normal 追加当前文件、Visual 追加选区，并按引用去重且保持代码 pane 焦点；Context 区编号展示，支持按编号删除、清空和消息区 `d`/`D` 快捷操作。
- 预防：测试必须覆盖 Normal/Visual `append_context` 焦点保持、重复追加去重、Context 单项删除和清空。
- commitID：93b7b95

## 2026-06-29：Chat pane buffer 需要稳定命名

- 问题：Chat panel 使用未命名 scratch/no-file buffer，部分状态栏或 winbar 插件会把 pane 标成 `scratch`，造成 UI 噪音。
- 方案：为 message/input/status 三个临时 buffer 设置稳定名称 `opencode-chat://messages`、`opencode-chat://input`、`opencode-chat://status`。
- 预防：测试必须断言三个 Chat pane buffer 名称稳定，避免回退成未命名 scratch buffer。
- commitID：31ffc3e

## 2026-06-29：Streaming 必须解析 delta 事件并按 SSE 边界派发

- 问题：streaming 只识别单行 `data:` 中的 `message.part.updated`，真实 opencode 常用 `message.part.delta`，导致 UI 只能等最终 HTTP 响应后一次性显示完整回复。
- 方案：SSE 客户端改为按空行事件边界聚合 `data:` 后解码；server 层同时支持 `message.part.delta` 增量累积和 `message.part.updated` 全量更新，并按 session 过滤事件。
- 预防：fake opencode 必须提供 `/event/subscribe` 并发送分片 delta；测试必须断言请求完成前 assistant 文本已经开始渲染。
- commitID：84111de

## 2026-06-29：Session 列表需要兼容包装响应

- 问题：真实 project session API 可能返回 `data.sessions`、`sessions`、`items` 或对象 map，原逻辑只按数组根/`data` 遍历，导致 `<leader>Xl` 打开 picker 但 sessions 为空。
- 方案：统一提取 session list payload，兼容多种包装和 id/project/path 字段名；本进程创建的 session 缓存补齐当前 project/root，便于 API 空列表时 fallback。
- 预防：fake opencode 的 project session 响应改为 `data.sessions` 包装，测试必须继续覆盖 session picker 能显示当前 project sessions 且过滤其它 workspace。
- commitID：c9f6028

## 2026-06-29：Project sessions 为空也必须 fallback

- 问题：project session API 返回 200 但空列表时，逻辑把它当成功终态，直接展示 `(empty)`，不会再查全局 `/session`；同时 `/project` 的 wrapped 响应也可能导致 project id 解析不稳。
- 方案：增强 `/project` 列表解析；project sessions 成功但为空时继续查询全局 sessions，按当前 project/root 过滤并与缓存去重合并。
- 预防：fake opencode 让 `/project/:id/session` 返回空、`/session` 返回 wrapped items，测试必须仍能在 session picker 中看到当前 project sessions 且过滤 foreign session。
- commitID：f407c54

## 2026-06-29：真实全局 session fallback 是 `/api/session`

- 问题：上一轮修复仍把 fallback 写到 `GET /session`，fake server 也错误接受该路径；真实 opencode 的全局 session 列表是 v2 `GET /api/session`，所以实测 picker 仍显示 `(empty)`。
- 方案：`list_sessions` 先尝试兼容 `/session`，失败后请求 `/api/session`；fake server 改为让 `/session` 返回 404，只通过 `/api/session` 返回 wrapped `items`。
- 预防：测试桩不能只模拟我们猜测的接口，涉及真实 opencode 路径时必须让错误旧路径失败，确保 fallback 覆盖真实 API。
- commitID：be39383

## 2026-06-29：当前 project 应优先来自 `/project/current`

- 问题：从 `/project` 列表中按目录匹配失败时会退化为第一个 project，真实环境多 project 时可能选错 project id，导致 `/project/:id/session` 返回空并让 picker 显示 `(empty)`。
- 方案：获取 project id 时优先请求 `GET /project/current`；仅不支持时回退到 `/project` 列表匹配，同时对 project/session id 做 URL 编码。
- 预防：fake opencode 的 `/project` 列表必须包含一个错误首项，并通过 `/project/current` 返回正确 project，测试仍需保证 session picker 能显示当前 project sessions。
- commitID：c4364cc

## 2026-06-29：所有 session 来源都必须二次过滤

- 问题：测试只覆盖了 fallback 全局列表过滤，没覆盖 project session endpoint 本身混入其它 workspace 的情况；真实环境下 picker 因信任 scoped endpoint 而显示了全机 sessions。
- 方案：无论 session 来自 `/project/:id/session`、`/session` 还是 `/api/session`，统一按当前 project id/root 二次过滤；过滤逻辑兼容顶层和嵌套 `session.project` 字段。
- 预防：fake opencode 的 project session endpoint 必须故意返回当前项目 session 加 foreign session，测试必须断言 foreign session 不出现在 picker 中。
- commitID：6d89789

## 2026-06-29：Session 作用域应优先使用 directory

- 问题：某些真实 workspace 会共享 `projectID`（例如 `global`），旧逻辑只要 projectID 相同就放行，导致不同 directory 的 sessions 混入当前 picker。
- 方案：`session_matches_project` 改为 directory/root 优先；当 session 和当前 root 都有目录信息时必须目录相等，只有缺少目录信息时才回退 projectID。
- 预防：fixture 中 foreign session 必须使用与当前 session 相同的 projectID 但不同 directory，测试必须确保它被过滤掉。
- commitID：df90f38

## 2026-06-29：Session 管理应贴近 picker 内操作

- 问题：用独立全局快捷键重命名 session 不直观，且 session picker 只能选择不能删除，管理历史会话不方便。
- 方案：session picker 增加 item-level actions：选中项按 `r` 重命名，按 `d` 后确认删除；新增 session 删除 client/server/command 路径，并让 picker 在操作后刷新。
- 预防：测试必须覆盖 picker 内 `r` 重命名、`d` 确认删除、DELETE 请求落到 fake server，以及推荐 keymap 不再注册 `<leader>Xr`。
- commitID：72c2365

## 2026-06-29：孤立 Chat panes 应自动清理

- 问题：用户关闭代码窗口后，当前 tab 可能只剩 opencode-chat 的 message/input/status panes，形成无用孤立 Chat panel。
- 方案：监听窗口关闭/切 tab 后延迟检查当前 tab；若剩余窗口全是 opencode-chat buffer/window，则先创建普通空窗口保活，再关闭所有 Chat panes。
- 预防：测试必须在独立 tab 中关闭唯一代码窗口，并断言 Chat panes 自动消失且只留下普通非 Chat 窗口。
- commitID：ea22654

## 2026-06-29：多 tab 下不要为空白 buffer 保活

- 问题：孤立 Chat panes 清理时总是先创建普通空窗口，导致多 tab 场景下当前 tab 被清理后仍残留一个空白 buffer。
- 方案：当前 tab 只剩 Chat panes 且存在其它 tab 时直接关闭当前 tab；只有最后一个 tab 时才创建普通空窗口保活。
- 预防：测试必须覆盖多 tab 场景：关闭唯一代码窗口后，当前 Chat-only tab 应消失并回到原 tab，而不是留下空白 buffer。
- commitID：baf0359

## 2026-06-29：最后一个 tab 应恢复代码 buffer

- 问题：最后一个 tab 只剩 Chat panes 时不能关闭 tab，旧逻辑用 `enew` 保活，仍会留下空白 buffer。
- 方案：记录打开 Chat 前最近的普通代码 buffer；最后一个 tab 清理 Chat panes 时优先重新加载并恢复该 buffer，只有找不到普通 buffer 时才创建空窗口。
- 预防：测试必须覆盖单 tab 场景：关闭唯一代码窗口后，Chat panes 自动清理并恢复原代码 buffer，而不是空白 buffer。
- commitID：c6be2d1

## 2026-06-29：最后代码窗口关闭后应允许 Neovim 退出

- 问题：用户在最后一个代码窗口执行 `:q` 时，Chat panes 是附属窗口，不应恢复代码 buffer 或留下空白 buffer；同时直接逐个关闭 Chat window 会因最后窗口限制中断后续退出逻辑。
- 方案：多 tab 时仍关闭 Chat-only tab；最后一个 tab 只剩 Chat panes 时执行 `quitall!`，并将普通 `hide()` 的 window close 包进 `pcall`，避免最后窗口错误打断流程。
- 预防：测试必须用子进程覆盖最后一个 tab 场景，关闭唯一代码窗口后 Neovim 应正常退出；若未退出则子进程 `cquit` 失败。
- commitID：8c4c97c
