local config = require("opencode_chat.config")

local M = {}

local uv = vim.uv or vim.loop
local last_path = nil
local last_root = nil

local function normalize(path)
  return vim.fs.normalize(path)
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function dirname(path)
  return vim.fs.dirname(path)
end

local function is_uri(path)
  return type(path) == "string" and path:match("^[%w%+%-%.]+://") ~= nil
end

local function usable_path(path)
  if type(path) ~= "string" or path == "" or is_uri(path) then
    return nil
  end
  path = normalize(path)
  local stat = uv.fs_stat(path)
  if stat then
    return path
  end
  local parent = dirname(path)
  if parent and uv.fs_stat(parent) then
    return path
  end
  return nil
end

local function buffer_path(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return usable_path(vim.api.nvim_buf_get_name(bufnr))
end

local function visible_file_path()
  local current = buffer_path(0)
  if current then
    return current
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local path = buffer_path(vim.api.nvim_win_get_buf(win))
    if path then
      return path
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local path = buffer_path(buf)
    if path then
      return path
    end
  end

  return nil
end

local function remember(path, project_root)
  if path and project_root then
    last_path = path
    last_root = project_root
  end
end

function M.find(startpath)
  local cfg = config.get()
  local path = usable_path(startpath) or visible_file_path() or usable_path(last_path)

  if path == nil or path == "" then
    path = uv.cwd()
  end

  path = normalize(path)
  local stat = uv.fs_stat(path)
  local dir = stat and stat.type == "directory" and path or dirname(path)
  if not dir or dir == "" then
    dir = uv.cwd()
  end
  local fallback_dir = normalize(dir)

  while dir and dir ~= "" do
    for _, marker in ipairs(cfg.root_markers) do
      if exists(dir .. "/" .. marker) then
        remember(path, dir)
        return dir
      end
    end

    local parent = dirname(dir)
    if not parent or parent == dir then
      break
    end
    dir = parent
  end

  local fallback = fallback_dir or normalize(uv.cwd())
  remember(path, fallback)
  return fallback
end

function M.last()
  return last_root, last_path
end

function M.relative(path, root)
  root = normalize(root or M.find(path))
  path = normalize(path)

  if path == root then
    return "."
  end

  local prefix = root .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end

  return path
end

return M
