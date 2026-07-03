local config = require("opencode_chat.config")
local debug = require("opencode_chat.debug")

local M = {}

local function log_args(args)
  local out = {}
  local hide_next = false
  for _, arg in ipairs(args or {}) do
    if hide_next then
      table.insert(out, "<redacted>")
      hide_next = false
    else
      table.insert(out, arg)
      if arg == "--data" or arg == "-d" then
        hide_next = true
      end
    end
  end
  return out
end

local function url(path, opts)
  opts = opts or {}
  local host = opts.host or config.get().host
  local port = assert(opts.port or config.get().port, "opencode port is required")
  return string.format("http://%s:%s%s", host, port, path)
end

local function query_value(value)
  return tostring(value):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

local function path_segment(value)
  return tostring(value):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

function M.app_url(opts)
  return url("/app", opts)
end

function M.doc_url(opts)
  return url("/doc", opts)
end

function M.session_url(opts)
  return url("/session", opts)
end

function M.legacy_session_url(opts)
  return url("/api/session", opts)
end

function M.api_sessions_url(opts)
  return url("/api/session", opts)
end

function M.message_url(session_id, opts)
  return url("/session/" .. session_id .. "/message", opts)
end

function M.abort_url(session_id, opts)
  return url("/session/" .. session_id .. "/abort", opts)
end

function M.rename_session_url(session_id, opts)
  return url("/session/" .. session_id, opts)
end

function M.delete_session_url(session_id, opts)
  local target = "/session/" .. path_segment(session_id)
  if opts and opts.directory and opts.directory ~= "" then
    target = target .. "?directory=" .. query_value(opts.directory)
  end
  return url(target, opts)
end

function M.v1_abort_url(session_id, opts)
  return url("/v1/sessions/" .. session_id .. "/abort", opts)
end

function M.legacy_prompt_url(session_id, opts)
  return url("/api/session/" .. session_id .. "/prompt", opts)
end

function M.project_url(opts)
  return url("/project", opts)
end

function M.current_project_url(opts)
  return url("/project/current", opts)
end

function M.project_messages_url(project_id, session_id, opts)
  return url("/project/" .. path_segment(project_id) .. "/session/" .. path_segment(session_id) .. "/message", opts)
end

function M.project_sessions_url(project_id, opts)
  return url("/project/" .. path_segment(project_id) .. "/session", opts)
end

function M.run(args, cb)
  debug.log("client", "run", { cmd = args and args[1], args = log_args(args) })
  if vim.system then
    return vim.system(args, { text = true }, function(result)
      debug.log("client", "run.done", { cmd = args and args[1], code = result and result.code, stderr = debug.preview(result and result.stderr), stdout_len = result and result.stdout and #result.stdout or 0 })
      if cb then
        cb(result)
      end
    end)
  end

  local result = vim.fn.system(args)
  local code = vim.v.shell_error
  debug.log("client", "run.done", { cmd = args and args[1], code = code, stdout_len = #tostring(result or "") })
  if cb then
    cb({ code = code, stdout = result, stderr = code == 0 and "" or result })
  end
  return nil
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

local function with_timeout(args, timeout_ms)
  if not timeout_ms or timeout_ms <= 0 then
    return args
  end
  local copy = vim.deepcopy(args)
  table.insert(copy, "--max-time")
  table.insert(copy, tostring(math.max(1, math.ceil(timeout_ms / 1000))))
  return copy
end

local function finish(result, cb)
  local body, status = split_body_status(result.stdout)
  result.body = body
  result.status = status
  local stderr = result.stderr and result.stderr ~= "" and result.stderr or nil
  result.error = stderr or body or result.stdout or ""
  local ok = result.code == 0 and status and status >= 200 and status < 300
  debug.log("client", "http.done", { ok = ok, status = status, code = result.code, body_len = #(body or ""), error = debug.preview(result.error) })
  cb(ok, decode_json(body), result)
end

function M.format_error(result, fallback)
  if not result then
    return fallback or "opencode request failed"
  end
  local body = result.body or result.stdout or result.stderr or ""
  if result.status then
    if body ~= "" then
      return string.format("HTTP %d: %s", result.status, body)
    end
    return string.format("HTTP %d", result.status)
  end
  if result.code and result.code ~= 0 then
    return string.format("command failed (%s): %s", result.code, body ~= "" and body or (fallback or "opencode request failed"))
  end
  return body ~= "" and body or (fallback or "opencode request failed")
end

local function get_json(target_url, cb, timeout_ms)
  return M.run(with_status(with_timeout({ "curl", "-sS", target_url }, timeout_ms)), function(result)
    finish(result, cb)
  end)
end

local function post_json(target_url, payload, cb, timeout_ms)
  return M.run(with_status(with_timeout({
    "curl",
    "-sS",
    "-X",
    "POST",
    target_url,
    "-H",
    "Content-Type: application/json",
    "--data",
    vim.json.encode(payload),
  }, timeout_ms)), function(result)
    finish(result, cb)
  end)
end

local function patch_json(target_url, payload, cb)
  return M.run(with_status({
    "curl",
    "-sS",
    "-X",
    "PATCH",
    target_url,
    "-H",
    "Content-Type: application/json",
    "--data",
    vim.json.encode(payload),
  }), function(result)
    finish(result, cb)
  end)
end

local function delete_json(target_url, cb)
  return M.run(with_status({
    "curl",
    "-sS",
    "-X",
    "DELETE",
    target_url,
  }), function(result)
    finish(result, cb)
  end)
end

local function text_from_parts(parts)
  local out = {}
  if type(parts) ~= "table" then
    return ""
  end
  for _, part in ipairs(parts) do
    if type(part) == "table" and part.type == "text" and type(part.text) == "string" and part.text ~= "" then
      table.insert(out, part.text)
    end
  end
  return table.concat(out, "\n")
end

local function model_object(model)
  if type(model) == "table" then
    return {
      providerID = model.providerID,
      modelID = model.modelID or model.id,
    }
  end
  if type(model) ~= "string" or model == "" then
    return nil
  end
  local provider_id, model_id = model:match("^([^/]+)/(.+)$")
  if not provider_id or not model_id then
    return nil
  end
  return { providerID = provider_id, modelID = model_id }
end

local function session_model(model, variant)
  local value = model_object(model)
  if value and value.modelID then
    value.id = value.modelID
    value.modelID = nil
  end
  local model_variant = variant or (type(model) == "table" and model.variant)
  if value and model_variant and model_variant ~= "" then
    value.variant = model_variant
  end
  return value
end

function M.extract_message_text(message)
  if type(message) ~= "table" then
    return ""
  end
  if message.info and message.info.role == "assistant" then
    return text_from_parts(message.parts)
  end
  if message.message and message.message.role == "assistant" and type(message.message.text) == "string" then
    return message.message.text
  end
  return ""
end

function M.extract_assistant_text(messages)
  if type(messages) ~= "table" then
    return ""
  end
  for index = #messages, 1, -1 do
    local text = M.extract_message_text(messages[index])
    if text ~= "" then
      return text
    end
  end
  return ""
end

function M.get_project_id(directory, opts, cb)
  local function project_id_from(project)
    return type(project) == "table" and (project.id or project.projectID or project.projectId or project.project_id) or nil
  end

  local function project_dir_from(project)
    return type(project) == "table" and (project.worktree or project.path or project.directory or project.cwd) or nil
  end

  get_json(M.current_project_url(opts), function(current_ok, current_data)
    local current_project = current_data and (current_data.data or current_data)
    local current_id = project_id_from(current_project)
    if current_ok and current_id then
      cb(true, current_id, current_data)
      return
    end

  get_json(M.project_url(opts), function(ok, data, result)
    if not ok then
      cb(false, nil, data, result)
      return
    end
    local projects = data and (data.data or data)
    if type(projects) == "table" then
      projects = projects.projects or projects.items or projects.list or projects
    end
    if type(projects) ~= "table" then
      cb(false, nil, data, result)
      return
    end
    local first_id
    local current_dir = directory and vim.fs.normalize(directory) or nil
    for _, project in pairs(projects) do
      local project_id = project_id_from(project)
      local project_dir = project_dir_from(project)
      project_dir = project_dir and vim.fs.normalize(project_dir) or nil
      first_id = first_id or project_id
      if current_dir and project_dir == current_dir then
        cb(project_id ~= nil, project_id, data, result)
        return
      end
    end
    cb(first_id ~= nil, first_id, data, result)
  end)
  end)
end

function M.create_session(directory, opts, cb)
  opts = opts or {}
  debug.log("client", "create_session", { directory = directory, url = M.session_url(opts), legacy_url = M.legacy_session_url(opts), model = opts.model, agent = opts.agent })
  local payload = { title = vim.fn.fnamemodify(directory, ":t") }
  if opts.agent then
    payload.agent = opts.agent
  end
  if opts.model then
    payload.model = session_model(opts.model)
  end

  return post_json(M.session_url(opts), payload, function(ok, data, result)
    local id = data and ((data.data and data.data.id) or data.id)
    debug.log("client", "create_session.session_done", { ok = ok, id = id, status = result and result.status, error = debug.preview(result and result.error) })
    if ok and id then
      cb(true, id, data, result, "session")
      return
    end

    post_json(M.legacy_session_url(opts), { directory = directory }, function(legacy_ok, legacy_data, legacy_result)
      local legacy_id = legacy_data and ((legacy_data.data and legacy_data.data.id) or legacy_data.id)
      debug.log("client", "create_session.legacy_done", { ok = legacy_ok, id = legacy_id, status = legacy_result and legacy_result.status, error = debug.preview(legacy_result and legacy_result.error) })
      cb(legacy_ok and legacy_id ~= nil, legacy_id, legacy_data, legacy_result, "legacy")
    end)
  end)
end

function M.send_message(session_id, text, opts, cb)
  opts = opts or {}
  debug.log("client", "send_message", { session_id = session_id, api_style = opts.api_style, url = M.message_url(session_id, opts), legacy_url = M.legacy_prompt_url(session_id, opts), text_len = #(text or ""), text_preview = debug.preview(text), model = opts.model, agent = opts.agent })
  local payload = { parts = { { type = "text", text = text } } }
  if opts.model then
    payload.model = model_object(opts.model)
  end
  if opts.agent then
    payload.agent = opts.agent
  end
  if opts.variant then
    payload.variant = opts.variant
  elseif type(opts.model) == "table" and opts.model.variant then
    payload.variant = opts.model.variant
  end
  local function send_legacy()
    local legacy_payload = { prompt = { text = text } }
    if opts.model then
      legacy_payload.model = opts.model
    end
    if opts.agent then
      legacy_payload.agent = opts.agent
    end
    if opts.variant then
      legacy_payload.variant = opts.variant
    end
    return post_json(M.legacy_prompt_url(session_id, opts), legacy_payload, function(legacy_ok, legacy_data, legacy_result)
      debug.log("client", "send_message.legacy_done", { session_id = session_id, ok = legacy_ok, status = legacy_result and legacy_result.status, error = debug.preview(legacy_result and legacy_result.error), reply_len = #(M.extract_message_text(legacy_data) or "") })
      cb(legacy_ok, legacy_data, legacy_result, M.extract_message_text(legacy_data), "legacy")
    end, opts.timeout_ms or config.get().response_timeout_ms)
  end

  if opts.api_style == "legacy" then
    return send_legacy()
  end

  return post_json(M.message_url(session_id, opts), payload, function(ok, data, result)
    debug.log("client", "send_message.session_done", { session_id = session_id, ok = ok, status = result and result.status, error = debug.preview(result and result.error), reply_len = #(M.extract_message_text(data) or "") })
    if ok then
      cb(true, data, result, M.extract_message_text(data), "session")
      return
    end

    if opts.api_style == "session" then
      cb(false, data, result, "", "session")
      return
    end

    return send_legacy()
  end, opts.timeout_ms or config.get().response_timeout_ms)
end

function M.list_sessions(opts, cb)
  return get_json(M.session_url(opts), function(ok, data, result)
    if ok then
      cb(ok, data, result, "session")
      return
    end
    get_json(M.api_sessions_url(opts), function(api_ok, api_data, api_result)
      cb(api_ok, api_data, api_result, "api")
    end)
  end)
end

function M.list_project_sessions(project_id, opts, cb)
  return get_json(M.project_sessions_url(project_id, opts), cb)
end

function M.rename_session(session_id, title, opts, cb)
  return patch_json(M.rename_session_url(session_id, opts), { title = title }, cb)
end

function M.delete_session(session_id, opts, cb)
  return delete_json(M.delete_session_url(session_id, opts), cb)
end

function M.extract_message_role_text(message)
  if type(message) ~= "table" then
    return nil, ""
  end
  if message.info and message.info.role then
    return message.info.role, text_from_parts(message.parts)
  end
  if message.message and message.message.role then
    return message.message.role, message.message.text or ""
  end
  return nil, ""
end

function M.to_chat_messages(messages)
  local out = {}
  if type(messages) ~= "table" then
    return out
  end
  for _, message in ipairs(messages) do
    local role, text = M.extract_message_role_text(message)
    if role and text ~= "" then
      local label = role:sub(1, 1):upper() .. role:sub(2)
      table.insert(out, { role = label, text = text })
    end
  end
  return out
end

M._model_object = model_object
M._session_model = session_model

function M.abort_session(session_id, opts, cb)
  opts = opts or {}
  return post_json(M.abort_url(session_id, opts), {}, function(ok, data, result)
    if ok then
      cb(true, data, result, "session")
      return
    end

    post_json(M.v1_abort_url(session_id, opts), {}, function(v1_ok, v1_data, v1_result)
      cb(v1_ok, v1_data, v1_result, "v1")
    end)
  end)
end

function M.get_messages(session_id, opts, cb)
  get_json(M.message_url(session_id, opts), cb)
end

function M.get_project_messages(project_id, session_id, opts, cb)
  get_json(M.project_messages_url(project_id, session_id, opts), cb)
end

function M.wait_for_assistant(session_id, opts, cb)
  opts = opts or {}
  debug.log("client", "wait_for_assistant", { session_id = session_id, timeout_ms = opts.timeout_ms, project_id = opts.project_id })
  local deadline = vim.loop.hrtime() + ((opts.timeout_ms or config.get().response_timeout_ms) * 1000000)
  local token = { cancelled = false, handle = nil }

  function token.cancel()
    token.cancelled = true
    if token.handle and token.handle.kill then
      pcall(function()
        token.handle:kill(15)
      end)
    end
  end

  local function poll()
    if token.cancelled then
      cb(false, "", nil, { body = "cancelled" })
      return
    end

    token.handle = M.get_messages(session_id, opts, function(ok, data, result)
      debug.log("client", "wait_for_assistant.poll_done", { session_id = session_id, ok = ok, status = result and result.status, text_len = #(ok and M.extract_assistant_text(data) or "") })
      if token.cancelled then
        cb(false, "", nil, { body = "cancelled" })
        return
      end
      local text = ok and M.extract_assistant_text(data) or ""
      if text ~= "" then
        cb(true, text, data, result)
        return
      end

      if not ok and opts.project_id then
        token.handle = M.get_project_messages(opts.project_id, session_id, opts, function(project_ok, project_data, project_result)
          debug.log("client", "wait_for_assistant.project_poll_done", { session_id = session_id, project_id = opts.project_id, ok = project_ok, status = project_result and project_result.status, text_len = #(project_ok and M.extract_assistant_text(project_data) or "") })
          if token.cancelled then
            cb(false, "", nil, { body = "cancelled" })
            return
          end
          local project_text = project_ok and M.extract_assistant_text(project_data) or ""
          if project_text ~= "" then
            cb(true, project_text, project_data, project_result)
            return
          end
          if vim.loop.hrtime() >= deadline then
            debug.log("client", "wait_for_assistant.timeout", { session_id = session_id, project = true })
            cb(false, "", project_data, project_result)
            return
          end
          vim.defer_fn(poll, 200)
        end)
        return
      end

      if vim.loop.hrtime() >= deadline then
        debug.log("client", "wait_for_assistant.timeout", { session_id = session_id, project = false })
        cb(false, "", data, result)
        return
      end
      vim.defer_fn(poll, 200)
    end)
  end

  poll()
  return token
end

function M.wait_until_ready(opts, cb)
  opts = opts or {}
  debug.log("client", "wait_until_ready", { url = M.app_url(opts), timeout_ms = opts.timeout_ms })
  local deadline = vim.loop.hrtime() + ((opts.timeout_ms or config.get().startup_timeout_ms) * 1000000)
  local function poll()
    M.run({ "curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", M.app_url(opts) }, function(result)
      debug.log("client", "wait_until_ready.poll_done", { code = result.code, stdout = tostring(result.stdout or ""), stderr = debug.preview(result.stderr) })
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
