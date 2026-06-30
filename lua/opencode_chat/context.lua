local root = require("opencode_chat.root")

local M = {}
local last_file = nil

local function current_file()
  local path = vim.api.nvim_buf_get_name(0)
  if path == nil or path == "" then
    path = last_file
  end
  if path == nil or path == "" then
    error("current buffer has no file name")
  end
  last_file = path
  return path
end

local function buffer_lines_or_file(bufnr, path)
  if vim.api.nvim_buf_get_name(bufnr) == path then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), vim.bo[bufnr].filetype
  end
  return vim.fn.readfile(path), vim.filetype.match({ filename = path }) or ""
end

local function visual_line_range()
  local mode = vim.api.nvim_get_mode().mode
  local is_active_visual = mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" or mode == "\19"
  local start_line = 0
  local end_line = 0

  if is_active_visual then
    start_line = vim.fn.getpos("v")[2]
    end_line = vim.fn.getpos(".")[2]
  end

  if start_line <= 0 or end_line <= 0 then
    start_line = vim.fn.line("'<")
    end_line = vim.fn.line("'>")
  end

  if start_line <= 0 or end_line <= 0 then
    error("visual selection marks are not available")
  end

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  return start_line, end_line
end

function M.file_reference(bufnr)
  bufnr = bufnr or 0
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == nil or path == "" then
    path = current_file()
  end
  last_file = path
  local project_root = root.find(path)
  return "@" .. root.relative(path, project_root), project_root
end

function M.file_item(bufnr)
  bufnr = bufnr or 0
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == nil or path == "" then
    path = current_file()
  end
  last_file = path
  local project_root = root.find(path)
  local relative = root.relative(path, project_root)
  local lines, ft = buffer_lines_or_file(bufnr, path)
  return {
    kind = "file",
    path = path,
    relative = relative,
    label = "@" .. relative,
    text = table.concat(lines, "\n"),
    ft = ft,
  }, project_root
end

function M.selection_reference(bufnr)
  bufnr = bufnr or 0
  local path = current_file()
  last_file = path
  local project_root = root.find(path)
  local start_line, end_line = visual_line_range()

  return string.format("@%s#L%d-L%d", root.relative(path, project_root), start_line, end_line), project_root
end

function M.selection_item(bufnr)
  bufnr = bufnr or 0
  local path = current_file()
  local project_root = root.find(path)
  local start_line, end_line = visual_line_range()
  local relative = root.relative(path, project_root)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  return {
    kind = "selection",
    path = path,
    relative = relative,
    range = { start_line, end_line },
    label = string.format("@%s#L%d-L%d", relative, start_line, end_line),
    text = table.concat(lines, "\n"),
    ft = vim.bo[bufnr].filetype,
  }, project_root
end

function M.buffer_item(bufnr)
  return M.file_item(bufnr or 0)
end

M._visual_line_range = visual_line_range

return M
