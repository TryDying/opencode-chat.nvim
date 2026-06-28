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
