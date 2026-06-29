# opencode-chat.nvim

轻量 Neovim 插件：用 Neovim 原生 floating buffers 实现 Chat UI，并通过 `opencode serve` 的本地 HTTP API 创建 session、发送 prompt，并让 opencode agent 执行文件修改。

## 功能

- `:OpencodeToggle` 打开/隐藏原生 Chat UI。
- `:OpencodeAsk [prompt]` 发送问题；不带参数时打开输入区。
- Chat 输入区按 `<C-s>` 提交。
- Chat UI 中 `<Tab>` 在消息区和输入区之间切换。
- Chat UI 中 `<C-c>` 或 `:OpencodeCancel` 通过 `POST /session/:id/abort` 取消当前请求。
- Chat UI 顶部可点击 `[Sessions] [New Session] [Model] [Variant]`。
- `:OpencodeAppendFile` 将当前文件引用和内容加入下一次提问上下文。
- `:OpencodeAppendSelection` 将 Visual 选区引用和内容加入下一次提问上下文。
- `:OpencodeEdit [instruction]` 使用配置的 opencode agent 执行文件修改，并渲染 assistant 总结。
- `:OpencodeSessions` / `<leader>Xl` 选择当前 project 的 session，`:OpencodeNewSession` / `<leader>Xn` 新建 session 且不重启 server。
- `:OpencodeModels` / `<leader>Xm` 选择白名单模型，`:OpencodeVariants` / `<leader>Xv` 按当前 provider 选择 variant。
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
})

vim.keymap.set("n", "<M-->", function()
  require("opencode_chat").toggle()
end, { desc = "Toggle opencode" })

vim.keymap.set("v", "<M-->", function()
  require("opencode_chat").append_selection()
end, { desc = "Append selection to opencode" })
```

`model` 使用 `provider/model` 格式，必须存在于 `providers` 白名单中；每个 provider 定义自己的 `variants`，每个 model 定义 `default_variant`。创建 session 时使用 `{ providerID, id, variant }`，发送 message 时使用 `{ providerID, modelID }` 并附带 `agent` / `variant`。

默认会绑定：

- Normal `<M-->`：toggle Chat UI
- Visual `<M-->`：追加选区上下文
- Normal `<leader>Xl` / `<leader>Xn` / `<leader>Xm` / `<leader>Xv`：选择 session、新建 session、选择 model、选择 variant

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
