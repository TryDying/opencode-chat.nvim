local config = require("opencode_chat.config")

local M = {}

local function url(path, opts)
  opts = opts or {}
  local host = opts.host or config.get().host
  local port = assert(opts.port or config.get().port, "opencode port is required")
  return string.format("http://%s:%s%s", host, port, path)
end

function M.app_url(opts)
  return url("/app", opts)
end

function M.append_url(opts)
  return url("/tui/append-prompt", opts)
end

local function run(args, cb)
  if vim.system then
    vim.system(args, { text = true }, cb)
    return
  end

  local result = vim.fn.system(args)
  local code = vim.v.shell_error
  if cb then
    cb({ code = code, stdout = result, stderr = code == 0 and "" or result })
  end
end

function M.append_prompt(text, opts, cb)
  opts = opts or {}
  local payload = vim.json.encode({ text = text })
  local args = {
    "curl",
    "-sS",
    "-X",
    "POST",
    M.append_url(opts),
    "-H",
    "Content-Type: application/json",
    "--data",
    payload,
  }

  run(args, function(result)
    local ok = result.code == 0
    if cb then
      cb(ok, result)
    elseif not ok then
      vim.schedule(function()
        vim.notify("opencode append-prompt failed: " .. (result.stderr or result.stdout or "unknown error"), vim.log.levels.ERROR)
      end)
    end
  end)
end

function M.wait_until_ready(opts, cb)
  opts = opts or {}
  local deadline = vim.loop.hrtime() + ((opts.timeout_ms or config.get().startup_timeout_ms) * 1000000)

  local function poll()
    run({ "curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", M.app_url(opts) }, function(result)
      if result.code == 0 and tostring(result.stdout or ""):match("^2") then
        cb(true)
        return
      end

      if vim.loop.hrtime() >= deadline then
        cb(false, result)
        return
      end

      vim.defer_fn(poll, 100)
    end)
  end

  poll()
end

return M
