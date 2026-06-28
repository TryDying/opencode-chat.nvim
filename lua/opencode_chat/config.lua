local M = {}

M.defaults = {
  command = "opencode",
  host = "127.0.0.1",
  port = nil,
  agent = "build",
  model = "deepseek/deepseek-v4-flash",
  variant = "low",
  keymaps = true,
  root_markers = { ".root", ".git", ".svn", ".hg", ".project", ".ccls" },
  startup_timeout_ms = 5000,
  response_timeout_ms = 30000,
  ui = {
    width = 0.9,
    height = 0.85,
    input_height = 5,
    border = "rounded",
    title = " opencode-chat ",
    input_title = " prompt (<C-s> submit) ",
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
