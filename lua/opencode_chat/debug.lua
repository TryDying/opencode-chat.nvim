local M = {}
local uv = vim.uv or vim.loop
local default_log = vim.fs.joinpath(vim.fn.stdpath("cache"), "opencode-chat.nvim.log")

local function logfile()
  local explicit = uv.os_getenv("OPENCODE_CHAT_DEBUG_LOG")
  if explicit and explicit ~= "" then
    return explicit
  end
  local enabled = uv.os_getenv("OPENCODE_CHAT_DEBUG")
  if enabled and enabled ~= "" and enabled ~= "0" and enabled:lower() ~= "false" then
    return default_log
  end
  return nil
end

local function safe_inspect(value)
  local ok, inspected = pcall(vim.inspect, value)
  if not ok then
    return tostring(value)
  end
  inspected = inspected:gsub("\n", " ")
  if #inspected > 4000 then
    return inspected:sub(1, 4000) .. "...(truncated)"
  end
  return inspected
end

function M.enabled()
  return logfile() ~= nil
end

function M.path()
  return logfile()
end

function M.log(scope, event, data)
  if vim.in_fast_event() then
    vim.schedule(function()
      M.log(scope, event, data)
    end)
    return
  end
  local path = logfile()
  if not path then
    return
  end
  local parent = vim.fs.dirname(path)
  if parent and parent ~= "" then
    pcall(vim.fn.mkdir, parent, "p")
  end
  local line = string.format("%s [%s] %s %s", os.date("!%Y-%m-%dT%H:%M:%SZ"), scope or "opencode_chat", event or "event", data ~= nil and safe_inspect(data) or "")
  pcall(vim.fn.writefile, { line }, path, "a")
end

function M.preview(text, limit)
  text = tostring(text or "")
  limit = limit or 120
  text = text:gsub("\n", "\\n")
  if #text > limit then
    return text:sub(1, limit) .. "...(truncated)"
  end
  return text
end

return M
