# opencode-chat.nvim

轻量 Neovim 插件：用 Neovim 原生 floating buffers 实现 Chat UI，并通过 `opencode serve` 的本地 HTTP API 创建 session、发送 prompt，并让 opencode agent 执行文件修改。

## 功能

- `:OpencodeToggle` 打开/隐藏原生 Chat UI。
- `:OpencodeAsk [prompt]` 发送问题；不带参数时打开输入区。
- Chat 输入区按 `<C-s>` 提交。
- `:OpencodeAppendFile` 将当前文件引用和内容加入下一次提问上下文。
- `:OpencodeAppendSelection` 将 Visual 选区引用和内容加入下一次提问上下文。
- `:OpencodeEdit [instruction]` 使用配置的 opencode agent 执行文件修改，并渲染 assistant 总结。
- `:OpencodeNewSession` 停止当前 server 并创建新 session。
- `:OpencodeStop` 停止 opencode job 并关闭插件窗口。

## 配置示例

```lua
require("opencode_chat").setup({
  agent = "build",
  model = "deepseek/deepseek-v4-flash",
  variant = "low",
})

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
