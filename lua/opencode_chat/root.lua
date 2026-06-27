local config = require("opencode_chat.config")

local M = {}

local uv = vim.uv or vim.loop

local function normalize(path)
  return vim.fs.normalize(path)
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function dirname(path)
  return vim.fs.dirname(path)
end

function M.find(startpath)
  local cfg = config.get()
  local path = startpath or vim.api.nvim_buf_get_name(0)

  if path == nil or path == "" then
    path = uv.cwd()
  end

  path = normalize(path)
  local stat = uv.fs_stat(path)
  local dir = stat and stat.type == "directory" and path or dirname(path)
  if not dir or dir == "" then
    dir = uv.cwd()
  end

  while dir and dir ~= "" do
    for _, marker in ipairs(cfg.root_markers) do
      if exists(dir .. "/" .. marker) then
        return dir
      end
    end

    local parent = dirname(dir)
    if not parent or parent == dir then
      break
    end
    dir = parent
  end

  return normalize(uv.cwd())
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
