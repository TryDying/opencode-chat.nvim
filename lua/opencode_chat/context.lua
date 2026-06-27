local root = require("opencode_chat.root")

local M = {}

local function current_file()
  local path = vim.api.nvim_buf_get_name(0)
  if path == nil or path == "" then
    error("current buffer has no file name")
  end
  return path
end

function M.file_reference(bufnr)
  bufnr = bufnr or 0
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == nil or path == "" then
    error("buffer has no file name")
  end
  local project_root = root.find(path)
  return "@" .. root.relative(path, project_root), project_root
end

function M.selection_reference(bufnr)
  bufnr = bufnr or 0
  local path = current_file()
  local project_root = root.find(path)
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")

  if start_line <= 0 or end_line <= 0 then
    error("visual selection marks are not available")
  end

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  return string.format("@%s#L%d-L%d", root.relative(path, project_root), start_line, end_line), project_root
end

return M
