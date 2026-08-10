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

## 2026-06-29：Chat UI 需要 tab mirror 窗口模型

- 问题：多 tab 编辑不同文件时，每个 tab 都希望有自己的右侧 Chat panes，但它们应共享同一个 opencode server/session/chat 状态和输入草稿。
- 方案：UI window 状态改为 `state.tabs[tabpage]` 的 tab-local panes；message/input/status buffers 和 messages/context/session/status 仍为进程级共享。当前 tab toggle 负责 reveal/focus，焦点在 Chat 内时隐藏所有 tab 的 Chat UI。
- 预防：测试必须覆盖 tab1/tab2 同时打开 Chat、共享 messages 和 input draft，以及在一个 Chat 内 toggle 会关闭所有 tab 的 Chat panes。
- commitID：8839a9e

## 2026-06-29：Mirror 可见状态也必须全局同步

- 问题：上一轮只实现了“多个已打开 Chat panes 共享内容”，但新建/切入 tab 时不会自动显示 Chat，仍不符合 file explorer 类 mirror 模式。
- 方案：新增全局 `visible` 状态；Chat 可见时，`TabEnter`/`TabNewEntered` 自动为当前 tab 创建 Chat panes；隐藏操作关闭所有 tab 并清除 visible。关闭 Chat-only tab 时若没有其它 Chat panes，需同步清除 visible，避免切回其它 tab 又自动重开。
- 预防：测试必须覆盖 Chat 全局可见时新 tab 自动出现 Chat mirror，而不是手动 toggle 后才出现。
- commitID：bc3b6b9

## 2026-07-01：Provider 配置不能依赖 Lua 标识符语法

- 问题：真实 provider ID 可能包含 `-`（如 `opencode-go`），若文档和配置只展示 `provider = { ... }` 形式，用户容易误以为这类 provider 无法配置。
- 方案：配置归一化支持 array-style provider 条目 `{ id = "opencode-go", ... }`，同时文档说明也可使用 `["opencode-go"] = { ... }`。
- 预防：测试必须覆盖含连字符 provider ID 的模型选择，避免后续重构把 provider ID 限制回 Lua bare key。
- commitID：1dad14d

## 2026-07-01：Toggle 快捷键应覆盖 Insert 模式

- 问题：用户在 Insert 模式写代码时触发 `<M-->`，若只注册 Normal map，需要先手动 `<Esc>`，否则快捷键容易失效。
- 方案：配置的 toggle keymap 同时注册 Normal/Insert；Insert 回调先 `stopinsert`，再调度执行原 reveal/focus/hide toggle 逻辑。
- 预防：测试必须断言推荐 toggle 在 Insert 模式也有映射，后续 keymap 重构不能只保留 Normal 入口。
- commitID：9b0c790

## 2026-07-01：Root 识别不能把 Chat buffer 当项目路径

- 问题：焦点在 opencode-chat pane 时打开 session 列表，root 推断可能落到 `opencode-chat://` buffer 或启动 cwd，导致按错误 project/root 过滤后 sessions 为空。
- 方案：`root.find()` 跳过 URI/插件 buffer，优先使用当前 tab/已打开 buffer 中的真实文件路径，并缓存最近真实文件 root。
- 预防：测试必须覆盖焦点位于 Chat input 时仍能从可见代码窗口推断项目 root，避免 session/root 逻辑重新依赖当前 buffer。
- commitID：c4147d8

## 2026-07-01：Session picker 应隐藏内部 subagent 会话

- 问题：opencode API 会返回同 project/root 下的 subagent/internal sessions，但 `opencode session list` 默认不展示；插件只按 project/root 过滤会把大量 runner/code-explorer 子会话暴露给用户。
- 方案：session 收集阶段增加用户可见性过滤，隐藏带 parent session、kind/source 标记为 subagent，或标题形如 `(@runner subagent)` 的内部会话。
- 预防：fake server 必须返回同 project 的 subagent session，测试断言 picker 不显示其 id/title，避免再次只按 project/root 过滤。
- commitID：4738ad1

## 2026-07-01：快速答疑需要独立临时会话

- 问题：用户临时追问旁支问题时，如果复用主 Chat session/context，会污染连续对话历史，也难以做到关闭后无痕。
- 方案：新增 Quick Ask 浮动窗口，复用当前 agent/model/variant 和 opencode server，但使用独立临时 session 与独立 context；关闭或取消时删除临时 session。
- 预防：测试必须覆盖 Quick Ask 不替换主 session、不消费主 context、多轮复用临时 session，并在关闭/取消后调用 DELETE 清理。
- commitID：7765341

## 2026-07-01：Chat panes 应作为一个窗口组关闭

- 问题：用户对 message/input/status 任一 Chat pane 执行 `:q` 后，其它 pane 会孤立残留，需要重复关闭再重新打开。
- 方案：在 `QuitPre` 识别当前 Chat pane，并同步关闭同 tab 的 sibling panes；保留 WinClosed/TabEnter 自动清理作为兜底。
- 预防：测试必须覆盖对单个 Chat pane 执行 `:q` 后三窗格全部关闭，避免后续窗口生命周期改动再次拆散 pane 组。
- commitID：741dc2d

## 2026-07-01：Quick Ask floating panes 也需要同组关闭

- 问题：Quick Ask 也由 message/input/status 三个浮窗组成，用户对任一 pane 执行 `:q` 后其它浮窗残留，且临时 session 清理入口不明显。
- 方案：Quick Ask 在 `QuitPre` 识别当前 Quick pane 并调用完整 close 流程，同时为 input/status 补充 Normal `q` 关闭映射。
- 预防：测试必须覆盖对单个 Quick pane 执行 `:q` 后三浮窗全部关闭，并确认临时 session 被删除。
- commitID：831f04b

## 2026-07-01：Quick context 追加后也必须退出 Visual 模式

- 问题：Quick Ask 的 Visual context 追加复用了独立 UI 路径，没有像主 Chat 一样显式退出 Visual 模式，导致追加后仍停留在选区状态。
- 方案：`quick_ui.show()` 支持 `leave_visual`，Quick Visual context 追加在读取选区后传递该标记，渲染浮窗前退出 Visual/Select 模式。
- 预防：测试必须覆盖 `quick_append_context` 在 active Visual selection 下追加选区并退出 Visual 模式，避免 Quick 与主 Chat 行为分叉。
- commitID：96978ee

## 2026-07-01：Server 启动中请求必须排队等待 ready

- 问题：首次 Quick context 后立刻提问可能与 `opencode serve` 启动/ready 检测并发，旧 `ensure_server` 只要 job 存活就直接放行，导致后续请求卡在 Thinking。
- 方案：为 server 状态增加 `ready/starting/waiters`，启动中重复请求进入队列，ready 和 project id 初始化完成后统一回调；Quick context 追加时只预热 server 不创建 session。
- 预防：测试必须覆盖未打开主 Chat 时先 Quick context、再立即从 Quick input 提交的问题路径，防止启动竞态回归。
- commitID：e27efcb

## 2026-07-01：Debug 日志不能成为隐式时序修复

- 问题：Quick Ask 首次请求不开 debug 会卡住，开 debug 后因同步写日志变慢反而成功，说明真实依赖了事件订阅与 message 发送之间的隐式时序。
- 方案：保留文件 debug 日志用于定位，但把日志暴露出的时序依赖显式化为 `stream_subscribe_delay_ms`，建立事件订阅后短暂延迟再发送 message。
- 预防：遇到“开日志就好”的 Heisenbug 时，必须把日志带来的延迟/调度变化还原为明确逻辑，而不是继续依赖 debug 模式验证。
- commitID：ba85092

## 2026-07-01：禁用无收益的 SSE 流式路径

- 问题：真实使用中 SSE 没有带来可感知增量渲染，反而在首次 Quick context 后提问时引入事件订阅与 message 发送的时序竞态；固定延迟只能掩盖问题。
- 方案：移除 `/event/subscribe` 发送路径和 `stream_subscribe_delay_ms` workaround，主 Chat 与 Quick Ask 统一使用 message HTTP 响应，必要时再轮询 history，并给 message 请求加 `response_timeout_ms` 超时。
- 预防：测试必须断言发送消息不会打开 SSE 订阅；后续除非能证明流式收益大于竞态成本，否则不要重新引入 SSE。
- commitID：f98ede5

## 2026-07-03：Server ready 前退出必须唤醒等待请求

- 问题：真实 `opencode serve` 在 `/app` ready 前退出时，等待 server ready 的 Quick/UI 请求没有被唤醒，界面会一直停在 `Thinking...`。
- 方案：`job_exit` 在 starting 阶段调用等待队列并返回明确错误；`/app` ready 探测的单次 curl 增加短超时，避免单个探测进程拖垮整体 startup deadline。
- 预防：测试必须模拟 server 命令立即退出，断言 Quick Ask 从 `Thinking...` 进入 Error，而不是静默等待。
- commitID：9c6f573

## 2026-07-03：Server job 必须可诊断且退出时强清理

- 问题：动态端口来源不透明，fake/真实 `opencode serve` 可能在异常退出或 Neovim 退出后残留，且 server 启动失败时缺少 stdout/stderr/pid/exit code 诊断。
- 方案：记录动态端口、job id、OS pid、stdout/stderr tail 和 exit code；`server.stop()` 等待 job 退出，必要时 TERM/KILL；`VimLeavePre` 兜底调用 stop。
- 预防：测试必须覆盖 server 早退时错误包含 stderr/exit code，并断言 `opencode.stop()` 会等待 fake server job 退出。
- commitID：45d51d6

## 2026-07-11：慢模型不能被同步 message 请求超时截断

- 问题：`POST /session/:id/message` 是等待完整回复的同步接口，慢模型 30 秒内无响应会被 `curl --max-time` 判失败，取消/退出还可能与停 server 竞态导致连接重置。
- 方案：优先使用 `POST /session/:id/prompt_async` 异步提交，再按发送前 history baseline 轮询新 assistant，并等待 `time.completed` 或错误；超时/取消走真实 `/abort`，`stop()` 用同步 best-effort abort 后再停服务。
- 预防：测试必须模拟异步慢回复、未完成 partial assistant、多轮 history 和取消路径，避免再次把同步 HTTP 超时当作模型生成边界。
- commitID：04244f3

## 2026-08-10：长回复导致假性 timeout 错误（首次尝试：limit=1 — 失败）

- 问题：回复过长时 UI 显示 Error（session 仍然存活）。
- 第一次尝试：轮询时使用 `limit=1` 只拉最新 1 条消息。**方案失败**——opencode 分页语义是 `ORDER BY time_created DESC LIMIT N+1 → reverse → pop → 返回`，`limit=1` 实际返回倒数第 2 新的消息而非最新消息，导致轮询始终检查用户消息，`text_len` 永远为 0 直到超时。
- 关键教训：**opencode 的 `?limit=N` 不是"返回最新 N 条"，而是"从旧到新返回第一页"**。初页不包含最新一条消息（最新那条被 pop 用作 next cursor）。这个语义在 opencode 的 `MessageV2.page` 源码中明确定义。
- commitID：ccaaf29（broken），2c48101（revert）

## 2026-08-10：回退 limit=1 + 修复 timeout 错误消息

- 问题：limit=1 方案破坏了轮询正确性，且 timeout 分支用 `result.body or "timeout"` 导致 body 已有 HTTP 响应内容时不会被覆盖，UI 显示 `HTTP 200: [完整 JSON]` 而非 `assistant response timed out`。
- 方案：回退 limit 改动恢复全量拉取，timeout 处改为 `result.body = "assistant response timed out"` 直接赋值。保留 `decode_json` 错误日志和 `finish()` 204/202 处理。
- 预防：任何依赖外部服务分页语义的改动，必须先阅读服务端源码确认语义（不能仅凭参数名猜测）。长期方案采用 SSE 流式推送替代轮询，避免 JSON 膨胀问题。
- commitID：2c48101

## 2026-08-10：SSE 流式推送替代轮询

- 问题：GET /message 轮询拉取全部消息历史导致 JSON 膨胀，`limit` 因 opencode 分页语义（`ORDER BY DESC → reverse → pop` 导致初页不含最新消息）无法用于轮询。
- 方案：
  1. 新增 `lua/opencode_chat/sse.lua`：`vim.loop` TCP 直连 `GET /event`，按 `\n\n` 边界切 SSE 帧，兼容 opencode 真实格式（`properties.delta`）和 fixture 格式（`properties.part.text`），`session.idle`/`session.status`/`message.updated` 三重完成检测，30s 心跳 watchdog + 指数退避重连。
  2. **先 send_message_async 再 subscribe SSE**——消除旧 SSE 实现（commitID f98ede5）中先订阅后发送的时序竞态。
  3. `server.lua send_to_session` 移除 polling 和 baseline_count 预取，`send_async` 成功后直接 `subscribe_sse`；`send_sync` 保留用于 legacy fallback。
  4. fixture：SSE 路径改为 `/event`（+`?directory=`）、所有完成路径广播 `session.idle`、编辑/partial 路径加 0.1s 延迟防 SSE 订阅/广播竞态。
- 预防：后续任何流式实现必须确保"先发后订"时序；fixture 的 SSE 完成信号需覆盖 `session.idle`，不能仅依赖消息数组变更。
- commitID：9aa037f

## 2026-08-10：系统性重构 OpenCode 通信层

- 问题：
  1. 代码中保留了大量 legacy API fallback（`/api/session`、`/api/session/:id/prompt`、`/v1/sessions/:id/abort`），以及不存在的端点（`/project/:projectID/session`），增加了状态管理（`api_style`）和代码路径复杂度。
  2. `client.lua` 同时维护三套通信路径：async send + SSE、sync send、polling wait_for_assistant，实际生产只使用第一套。
  3. `send_to_session` 内 async→sync→SSE 三级 fallback 链，实际 sync 和 polling 从未触发但增加了竞态面和测试维护成本。
  4. 主 Chat 和 Quick Ask 的 request 生命周期逻辑（busy guard、spinner、build prompt、cancel）几乎完全重复。
  5. SSE 完成检测使用三重信号（`session.idle`/`session.status`/`message.updated`），其中 `message.updated` 不应作为请求完成信号。
  6. `extract_delta_text` 兼容双格式（真实 `properties.delta` 和 fixture `properties.part.text`），增加了不必要的兼容分支。
  7. "先 send_message_async 再 subscribe SSE" 的顺序存在早期 delta 丢失的竞态。

- 方案：
  1. **删除所有 legacy API 兼容代码**：移除 `legacy_session_url`、`api_sessions_url`、`legacy_prompt_url`、`v1_abort_url`、`project_sessions_url`、`project_messages_url` 等 URL 函数；移除 `send_message`（sync）、`wait_for_assistant`/`wait_for_assistant_after`（polling）、`extract_assistant_text`/`extract_assistant_after` 等函数；简化 `create_session`/`abort_session`/`list_sessions` 为单一路径。
  2. **统一通信路径为 async + SSE**：`server.lua` 删除 `send_sync`、`send_to_session` 内的 fallback 链、`api_style` 状态追踪；`send_async` + `subscribe_sse` 为唯一发送路径。
  3. **抽取 `chat.lua` 请求生命周期**：封装 "SSE subscribe → on_connected → prompt_async → stream → complete/error/cancel" 的通用模式，内置 spinner；`init.lua` 和 `quick.lua` 通过回调模式复用，消除 ~700 行重复代码。
  4. **修正 SSE 订阅顺序**：从"先发后订"改为**"先订 SSE → 收到 server.connected → 发 prompt_async"**，彻底消除早期 delta 丢失的竞态。
  5. **SSE 完成信号修正**：`session.status {type:"idle"}` 为主信号，`session.idle` 为 fallback；移除 `message.updated` 作为完成信号；删除 `properties.part.text` 兼容。
  6. **SSE 事件路由增强**：`process_event` 支持 `message.part.delta`、`session.next.text.delta`、`session.next.reasoning.delta`、`session.next.tool.*`、`session.error`、`session.status` 等事件类型，不删除任何事件处理能力。
  7. **修正 session list API**：确认 OpenCode v1.18.15 中 `/project/:projectID/session` 不存在，session 列表统一使用 `GET /session?scope=project&path=...`。
  8. **cancel 流程去重**：`on_cancelled` 回调改为 idempotent（扫描消息列表中的 "Thinking..."/"Cancelling..." 并替换），避免双重调用导致重复 "Cancelled" 消息。

- 结果：
  - 删除 ~1200 行旧代码，新增 ~640 行，净减少 ~560 行
  - 模块数从 14 增加到 15（新增 `chat.lua`，但 `quick.lua` 大幅瘦身）
  - `client.lua`: 830→360 行；`server.lua`: 827→380 行；`init.lua`: 570→300 行；`quick.lua`: 361→160 行
  - 消除了全部 7 个 legacy URL 函数、6 个 polling/wait 函数、`api_style` 状态追踪、三级 fallback 链
  - 所有测试通过

- 预防：
  1. SSE 顺序必须是"先订 SSE，收到 server.connected 后再发 prompt_async"，不要在代码中回到"先发后订"。
  2. 不要再添加 legacy API fallback / `api_style` 追踪；当前只支持 OpenCode v1.18.15+ 的 `/session`、`/session/:id/prompt_async`、`/event`、`/session/:id/abort` API。
  3. 不要再把 `session.next.step.ended` 作为请求完成信号（它是 durable step 结算事件，不是 session 空闲信号）。
  4. 不要再在 fixture 中添加 `properties.part.text` 格式的 delta 事件；统一使用 `properties.delta`。
  5. `chat.lua` 只负责一次 request 的生命周期，不要把 session 管理、context 构建、UI 渲染塞进去。

- commitID：6ab60e9

