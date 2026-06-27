# opencode-chat.nvim

轻量 Neovim 插件：用 Neovim 原生 floating buffer 实现最小 Chat UI，并通过 `opencode serve` 的本地 HTTP API 创建 session、发送 prompt。

## 功能

- `:OpencodeToggle` 打开/隐藏原生 Chat UI。
- `:OpencodeAsk [prompt]` 发送问题；不带参数时弹出输入框。
- `:OpencodeAppendFile` 将当前文件引用加入下一次提问上下文。
- `:OpencodeAppendSelection` 将 Visual 选区引用加入下一次提问上下文。
- `:OpencodeNewSession` 停止当前 server 并创建新 session。
- `:OpencodeStop` 停止 opencode job 并关闭插件窗口。

## 配置示例

```lua
require("opencode_chat").setup()

vim.keymap.set("n", "<M-->", function()
  require("opencode_chat").toggle()
end, { desc = "Toggle opencode" })

vim.keymap.set("v", "<M-->", function()
  require("opencode_chat").append_selection()
end, { desc = "Append selection to opencode" })
```

默认会绑定：

- Normal `<M-->`：toggle Chat UI
- Visual `<M-->`：追加选区上下文

## 验证

本仓库内置自闭环测试，不读取全局 Neovim 配置：

```sh
nvim --clean -u NONE --headless -l tests/run.lua
```

## 开发态启动

不修改全局 Neovim 配置，直接加载当前仓库插件并启动 Neovim：

```sh
./scripts/dev-nvim README.md
```
