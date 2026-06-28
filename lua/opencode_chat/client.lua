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

function M.project_url(opts)
  return url("/project", opts)
end

function M.project_session_url(project_id, opts)
  return url("/project/" .. project_id .. "/session", opts)
end

function M.prompt_url(session_id, opts)
  return url("/api/session/" .. session_id .. "/prompt", opts)
end

function M.messages_url(session_id, opts)
  return url("/session/" .. session_id .. "/message", opts)
end

function M.project_messages_url(project_id, session_id, opts)
  return url("/project/" .. project_id .. "/session/" .. session_id .. "/message", opts)
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

local function split_body_status(stdout)
  stdout = stdout or ""
  local body, status = stdout:match("^(.*)\n(%d%d%d)$")
  if status then
    return body, tonumber(status)
  end
  return stdout, nil
end

local function with_status(args)
  local copy = vim.deepcopy(args)
  table.insert(copy, "-w")
  table.insert(copy, "\n%{http_code}")
  return copy
end

local function get_json(target_url, cb)
  M.run(with_status({ "curl", "-sS", target_url }), function(result)
    local body, status = split_body_status(result.stdout)
    result.body = body
    result.status = status
    local ok = result.code == 0 and status and status >= 200 and status < 300
    if cb then
      cb(ok, decode_json(body), result)
    end
  end)
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

  M.run(with_status(args), function(result)
    local body, status = split_body_status(result.stdout)
    result.body = body
    result.status = status
    local ok = result.code == 0 and status and status >= 200 and status < 300
    if cb then
      cb(ok, decode_json(body), result)
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

function M.extract_assistant_text(messages)
  if type(messages) ~= "table" then
    return ""
  end

  for index = #messages, 1, -1 do
    local item = messages[index]
    local info = item and item.info
    if info and info.role == "assistant" and type(item.parts) == "table" then
      local parts = {}
      for _, part in ipairs(item.parts) do
        if type(part) == "table" and part.type == "text" and type(part.text) == "string" and part.text ~= "" then
          table.insert(parts, part.text)
        end
      end
      if #parts > 0 then
        return table.concat(parts, "\n")
      end
    end
  end

  return ""
end

function M.create_session(directory, opts, cb)
  opts = opts or {}
  post_json(M.session_url(opts), { directory = directory }, function(ok, data, result)
    local id = data and ((data.data and data.data.id) or data.id)
    cb(ok and id ~= nil, id, data, result)
  end)
end

function M.get_project_id(directory, opts, cb)
  opts = opts or {}
  get_json(M.project_url(opts), function(ok, data, result)
    if not ok then
      cb(false, nil, data, result)
      return
    end

    local projects = data and (data.data or data)
    if type(projects) ~= "table" then
      cb(false, nil, data, result)
      return
    end

    local first_id = nil
    for _, project in ipairs(projects) do
      first_id = first_id or project.id
      if project.worktree == directory or project.path == directory or project.directory == directory then
        cb(project.id ~= nil, project.id, data, result)
        return
      end
    end

    cb(first_id ~= nil, first_id, data, result)
  end)
end

function M.send_prompt(session_id, text, opts, cb)
  opts = opts or {}
  local payload = { prompt = { text = text } }
  if opts.model then
    payload.model = opts.model
  end

  post_json(M.prompt_url(session_id, opts), payload, function(ok, data, result)
    if not data and result and result.body then
      data = decode_json(result.body:match("({.*})"))
    end
    cb(ok, data, result, M.extract_text(data, result and (result.body or result.stdout) or ""))
  end)
end

function M.get_messages(session_id, opts, cb)
  opts = opts or {}
  get_json(M.messages_url(session_id, opts), cb)
end

function M.get_project_messages(project_id, session_id, opts, cb)
  opts = opts or {}
  get_json(M.project_messages_url(project_id, session_id, opts), cb)
end

local function get_any_messages(session_id, opts, cb)
  M.get_messages(session_id, opts, function(ok, data, result)
    if ok then
      cb(true, data, result)
      return
    end

    if opts.project_id then
      M.get_project_messages(opts.project_id, session_id, opts, cb)
      return
    end

    cb(false, data, result)
  end)
end

function M.wait_for_assistant(session_id, opts, cb)
  opts = opts or {}
  local deadline = vim.loop.hrtime() + ((opts.timeout_ms or config.get().startup_timeout_ms) * 1000000)

  local function poll()
    get_any_messages(session_id, opts, function(ok, data, result)
      local text = ok and M.extract_assistant_text(data) or ""
      if text ~= "" then
        cb(true, text, data, result)
        return
      end

      if vim.loop.hrtime() >= deadline then
        cb(false, text, data, result)
        return
      end

      vim.defer_fn(poll, 200)
    end)
  end

  poll()
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
