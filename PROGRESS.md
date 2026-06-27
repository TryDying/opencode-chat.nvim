# 经验教训记录

> 每次遇到问题或完成重要改动后在此记录，必须附上 git commitID。
> 仅记录重要 bug 修复或重大变更；不要记录初始化、脚手架生成、纯文档补全等噪音内容。

## 2026-06-27：MVP 通信边界落地

- 问题：opencode TUI 不能被当作可靠协议层，直接向 terminal 注入文本容易受焦点、paste mode 和 TUI key handling 影响。
- 方案：第一版只用 Neovim 原生 floating terminal 承载 TUI，实际上下文注入统一走 `POST /tui/append-prompt`。
- 预防：后续扩展仍应保持 terminal 仅负责显示；与 opencode 的编辑器通信优先通过本地 HTTP/API，并用仓库内 fake bridge 测试闭环。
- commitID：a5ac440
