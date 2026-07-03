# opencode-chat.nvim

轻量 Neovim 插件：用 Neovim 右侧 Chat panel 集成 `opencode serve` 的本地 HTTP API，创建 session、发送 prompt、管理上下文和历史会话，并让 opencode agent 执行文件修改。

## 功能

- `:OpencodeToggle` 打开/聚焦/隐藏右侧 Chat panel，默认占编辑器宽度 40%。
- `:OpencodeAsk [prompt]` 发送问题；不带参数时打开输入区。
- Chat 输入区按 `<C-s>` 提交。
- Chat UI 中 `<Tab>` 在消息区和输入区之间切换。
- Chat UI 中 `<C-c>` 或 `:OpencodeCancel` 通过 `POST /session/:id/abort` 取消当前请求。
- Chat UI 底部固定 status bar，显示 Idle/Thinking/Error 等状态和当前 model/variant。
- Chat UI 是 tab mirror：只要 Chat 当前可见，新建/切入 tab 会自动显示同一份 Chat；所有 tab 共享 messages、input 草稿、context、session 和状态。
- Chat UI 的 message/input/status 三个窗口作为一组关闭；对其中任意一个执行 `:q` 会同步关闭另外两个窗口。
- 当前 tab 只剩 opencode-chat 的 message/input/status 窗口时，会自动清理 Chat：有其它 tab 时关闭当前 tab，最后一个 tab 时允许 Neovim 正常退出。
- `:OpencodeAppendFile` 将当前文件引用和内容加入下一次提问上下文。
- `:OpencodeAppendSelection` 将 Visual 选区引用和内容加入下一次提问上下文。
- `:OpencodeAppendContext` 在 Normal 模式追加当前文件、Visual 模式追加选区；上下文自动去重，推荐映射为 `<leader>Xe`，追加后保持代码 pane 焦点。
- `:OpencodeContextRemove [index]` / `:OpencodeContextClear` 删除或清空上下文；消息区 Context 行上按 `d` 删除该项，按 `D` 清空全部。
- `:OpencodeEdit [instruction]` 使用配置的 opencode agent 执行文件修改，并渲染 assistant 总结。
- `:OpencodeSessions` 选择当前 project 的 session，picker 内按 `r` 重命名、按 `d` 并确认后删除；`:OpencodeNewSession` 新建 session 且不重启 server。
- `:OpencodeModels` 选择白名单模型，`:OpencodeVariants` 按当前 provider 选择 variant。
- `:OpencodeQuick [prompt]` 打开临时答疑浮窗，复用当前模型配置但使用独立临时 session；`:q`、Normal `q` 或 `:OpencodeQuickClose` 关闭后会删除临时 session。
- `:OpencodeStop` 停止 opencode job 并关闭插件窗口。

## 依赖

- 必需：Neovim、`curl`、可用的 `opencode` CLI。
- 推荐：`nui.nvim`。插件会优先用 `nui.menu` 渲染 session/model/variant 选择器；缺失时会退回内置浮窗选择器，便于测试和最小环境运行。

## 配置示例

```lua
require("opencode_chat").setup({
  agent = "build",
  model = "deepseek/deepseek-v4-flash",
  providers = {
    deepseek = {
      variants = { "low", "medium", "high", "max" },
      models = {
        { id = "deepseek-v4-flash", default_variant = "low" },
        { id = "deepseek-v4-pro", default_variant = "high" },
      },
    },
    -- provider ID 含有 `-` 时，可以使用 bracket key 或 array-style 写法。
    ["opencode-go"] = {
      variants = { "low", "medium", "high" },
      models = {
        { id = "qwen3-coder", default_variant = "medium" },
      },
    },
  },
  keymaps = {
    toggle = "<M-->",
    append_context = "<leader>Xe",
    append_selection = "<M-->",
    sessions = "<leader>Xl",
    new_session = "<leader>Xn",
    models = "<leader>Xm",
    variants = "<leader>Xt",
    quick = "<leader>Xq",
    quick_context = "<leader>XQ",
  },
  ui = {
    width = 0.4,
    height = 1.0,
    message_height = nil,
    input_height = 5,
  },
})
```

`model` 使用 `provider/model` 格式，必须存在于 `providers` 白名单中；每个 provider 定义自己的 `variants`，每个 model 定义 `default_variant`。Lua 标识符不能包含 `-`，因此 `opencode-go` 这类 provider 可以写成 `["opencode-go"] = { ... }`，也可以写成 `{ id = "opencode-go", variants = ..., models = ... }` 的 array-style provider 条目。创建 session 时使用 `{ providerID, id, variant }`，发送 message 时使用 `{ providerID, modelID }` 并附带 `agent` / `variant`。

插件不订阅 `/event/subscribe` SSE 事件流；发送 message 后优先使用 HTTP 响应中的 assistant 内容，必要时再轮询 message history，避免流式事件竞态。

插件默认不绑定全局快捷键；如需快捷键，请在 `keymaps` 中显式配置：

- Normal/Insert `<M-->`：toggle Chat UI；Insert 模式会先退出 insert，再执行打开/聚焦/隐藏逻辑
- Normal/Visual `<leader>Xe`：追加当前文件或 Visual 选区上下文，保持代码 pane 焦点
- Visual `<M-->`：旧选区上下文追加入口，会聚焦 Chat input
- Normal `<leader>Xl` / `<leader>Xn` / `<leader>Xm` / `<leader>Xt`：选择 session、新建 session、选择 model、选择 variant；session picker 内 `r` 重命名、`d` 确认删除
- Normal `<leader>Xq`：打开 Quick Ask 临时答疑；Normal/Visual `<leader>XQ`：向 Quick Ask 追加独立上下文

`:OpencodeToggle` 在当前 tab 面板隐藏时打开 Chat 镜像；当前 tab 面板已打开但当前焦点不在 Chat 内时，会重新聚焦到 Chat 输入区；焦点已在 Chat 内时会隐藏所有 tab 的 Chat UI。只要 Chat 处于可见状态，新建或切入 tab 会自动显示同一份 Chat 镜像。

## 验证

本仓库内置自闭环测试，使用 headless Neovim 运行：

```sh
nvim --headless -l tests/run.lua
```

## 开发态启动

不修改全局 Neovim 配置，直接加载当前仓库插件并启动 Neovim：

```sh
./scripts/dev-sandbox
```

该命令会创建并打开 `/tmp/opencode-chat.nvim-sandbox/src/example.lua`，不会使用仓库内受 Git 管理的文件做测试目标。
开发态脚本会显式注入推荐测试快捷键：`<M-->`、`<leader>Xe`、`<leader>Xl`、`<leader>Xn`、`<leader>Xm`、`<leader>Xt`、`<leader>Xq`、`<leader>XQ`；插件默认配置仍不注册全局快捷键。
