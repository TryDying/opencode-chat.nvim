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

function M.session_url(opts)
  return url("/api/session", opts)
end

function M.prompt_url(session_id, opts)
  return url("/api/session/" .. session_id .. "/prompt", opts)
end

function M.run(args, cb)
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

local function decode_json(text)
  if not text or text == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if ok then
    return decoded
  end
  return nil
end

local function post_json(target_url, payload, cb)
  local args = {
    "curl",
    "-sS",
    "-X",
    "POST",
    target_url,
    "-H",
    "Content-Type: application/json",
    "--data",
    vim.json.encode(payload),
  }

  M.run(args, function(result)
    local ok = result.code == 0
    if cb then
      cb(ok, decode_json(result.stdout), result)
    end
  end)
end

local function collect_text(value, out)
  out = out or {}
  if type(value) == "string" then
    if value ~= "" then
      table.insert(out, value)
    end
  elseif type(value) == "table" then
    for _, key in ipairs({ "text", "content", "message", "output" }) do
      if type(value[key]) == "string" and value[key] ~= "" then
        table.insert(out, value[key])
      end
    end
    for _, child in pairs(value) do
      if type(child) == "table" then
        collect_text(child, out)
      end
    end
  end
  return out
end

function M.extract_text(data, fallback)
  local parts = collect_text(data)
  if #parts == 0 then
    return fallback or ""
  end
  local seen = {}
  local unique = {}
  for _, part in ipairs(parts) do
    if not seen[part] then
      seen[part] = true
      table.insert(unique, part)
    end
  end
  return table.concat(unique, "\n")
end

function M.create_session(directory, opts, cb)
  opts = opts or {}
  post_json(M.session_url(opts), { directory = directory }, function(ok, data, result)
    local id = data and ((data.data and data.data.id) or data.id)
    cb(ok and id ~= nil, id, data, result)
  end)
end

function M.send_prompt(session_id, text, opts, cb)
  opts = opts or {}
  local payload = { prompt = { text = text } }
  if opts.model then
    payload.model = opts.model
  end

  post_json(M.prompt_url(session_id, opts), payload, function(ok, data, result)
    if not data and result and result.stdout then
      data = decode_json(result.stdout:match("({.*})"))
    end
    cb(ok, data, result, M.extract_text(data, result and result.stdout or ""))
  end)
end

function M.wait_until_ready(opts, cb)
  opts = opts or {}
  local deadline = vim.loop.hrtime() + ((opts.timeout_ms or config.get().startup_timeout_ms) * 1000000)

  local function poll()
    M.run({ "curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", M.app_url(opts) }, function(result)
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
