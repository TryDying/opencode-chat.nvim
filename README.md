# opencode-chat.nvim

轻量 Neovim 插件：用 Neovim 右侧 Chat panel 集成 `opencode serve` 的本地 HTTP API，创建 session、发送 prompt，并让 opencode agent 执行文件修改。

## 功能

- `:OpencodeToggle` 打开/隐藏右侧 Chat panel，默认占编辑器宽度 40%。
- `:OpencodeAsk [prompt]` 发送问题；不带参数时打开输入区。
- Chat 输入区按 `<C-s>` 提交。
- Chat UI 中 `<Tab>` 在消息区和输入区之间切换。
- Chat UI 中 `<C-c>` 或 `:OpencodeCancel` 通过 `POST /session/:id/abort` 取消当前请求。
- Chat UI 底部固定 status bar，显示 Idle/Thinking/Streaming/Error 等状态和当前 model/variant。
- `:OpencodeAppendFile` 将当前文件引用和内容加入下一次提问上下文。
- `:OpencodeAppendSelection` 将 Visual 选区引用和内容加入下一次提问上下文。
- `:OpencodeEdit [instruction]` 使用配置的 opencode agent 执行文件修改，并渲染 assistant 总结。
- `:OpencodeSessions` 选择当前 project 的 session，`:OpencodeNewSession` 新建 session 且不重启 server，`:OpencodeRenameSession [title]` 重命名当前 session。
- `:OpencodeModels` 选择白名单模型，`:OpencodeVariants` 按当前 provider 选择 variant。
- `:OpencodeStop` 停止 opencode job 并关闭插件窗口。

## 依赖

- 必需：Neovim、`curl`、可用的 `opencode` CLI。
- 推荐：`nui.nvim`。插件会优先用 `nui.menu` 渲染 session/model/variant 选择器；缺失时会退回内置浮窗选择器，便于测试和最小环境运行。

## 配置示例

```lua
require("opencode_chat").setup({
  agent = "quick",
  model = "deepseek/deepseek-v4-flash",
  providers = {
    deepseek = {
      variants = { "low", "medium", "high", "max" },
      models = {
        { id = "deepseek-v4-flash", default_variant = "low" },
        { id = "deepseek-v4-pro", default_variant = "high" },
      },
    },
  },
  keymaps = {
    toggle = "<M-->",
    append_selection = "<M-->",
    sessions = "<leader>Xl",
    new_session = "<leader>Xn",
    rename_session = "<leader>Xr",
    models = "<leader>Xm",
    variants = "<leader>Xt",
  },
  ui = {
    width = 0.4,
    height = 1.0,
    message_height = nil,
    input_height = 5,
  },
})
```

`model` 使用 `provider/model` 格式，必须存在于 `providers` 白名单中；每个 provider 定义自己的 `variants`，每个 model 定义 `default_variant`。创建 session 时使用 `{ providerID, id, variant }`，发送 message 时使用 `{ providerID, modelID }` 并附带 `agent` / `variant`。

如果当前 opencode server 支持 `/event/subscribe` SSE 事件流，插件会尝试根据 `message.part.updated` 增量刷新 assistant 回复；不可用时自动退回非流式响应。

插件默认不绑定全局快捷键；如需快捷键，请在 `keymaps` 中显式配置：

- Normal `<M-->`：toggle Chat UI
- Visual `<M-->`：追加选区上下文
- Normal `<leader>Xl` / `<leader>Xn` / `<leader>Xr` / `<leader>Xm` / `<leader>Xt`：选择 session、新建 session、重命名 session、选择 model、选择 variant

`:OpencodeToggle` 在面板隐藏时打开 Chat；面板已打开但当前焦点不在 Chat 内时，会重新聚焦到 Chat 输入区；焦点已在 Chat 内时才隐藏面板。

## 验证

本仓库内置自闭环测试，使用 `VIM_PROFILE=basic` 加载你的基础 Neovim profile：

```sh
VIM_PROFILE=basic nvim --headless -l tests/run.lua
```

## 开发态启动

不修改全局 Neovim 配置，直接加载当前仓库插件并启动 Neovim：

```sh
./scripts/dev-sandbox
```

该命令会创建并打开 `/tmp/opencode-chat.nvim-sandbox/src/example.lua`，不会使用仓库内受 Git 管理的文件做测试目标。
开发态脚本会显式注入推荐测试快捷键：`<M-->`、`<leader>Xl`、`<leader>Xn`、`<leader>Xr`、`<leader>Xm`、`<leader>Xt`；插件默认配置仍不注册全局快捷键。
