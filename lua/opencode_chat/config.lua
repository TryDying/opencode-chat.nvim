local M = {}

M.defaults = {
  command = "opencode",
  host = "127.0.0.1",
  port = nil,
  model = nil,
  keymaps = true,
  root_markers = { ".root", ".git", ".svn", ".hg", ".project", ".ccls" },
  startup_timeout_ms = 5000,
  ui = {
    width = 0.9,
    height = 0.85,
    border = "rounded",
    title = " opencode-chat ",
  },
}

local current = vim.deepcopy(M.defaults)

function M.setup(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return current
end

function M.get()
  return current
end

return M
