# opencode-chat.nvim

轻量 Neovim 插件：用原生 floating terminal 承载 opencode TUI，并通过 opencode 本地 HTTP bridge 追加当前文件或选区上下文。

## 功能

- `:OpencodeToggle` 打开/隐藏 opencode TUI。
- `:OpencodeAppendFile` 追加当前文件引用。
- `:OpencodeAppendSelection` 追加 Visual 选区引用。
- `:OpencodeNewSession` 停止当前 TUI 并创建新 session。
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

## 验证

本仓库内置自闭环测试，不读取全局 Neovim 配置：

```sh
nvim --clean -u NONE --headless -l tests/run.lua
```
