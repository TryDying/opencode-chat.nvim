local config = require("opencode_chat.config")
local M = {}
local connections = {}

local function key(opts)
  opts = opts or {}
  return (opts.host or config.get().host) .. ":" .. tostring(opts.port or config.get().port)
end

function M.connect(opts, password) connections[key(opts)] = password end
function M.disconnect(opts) connections[key(opts)] = nil end

local function encode(value)
  return tostring(value):gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end)
end

local function url(path, opts) return "http://" .. key(opts) .. path end
function M.app_url(opts) return url("/api/info", opts) end
function M.doc_url(opts) return url("/openapi.json", opts) end
function M.session_url(opts) return url("/api/session", opts) end
function M.message_url(id, opts) return url("/api/session/" .. encode(id) .. "/message", opts) end
function M.prompt_async_url(id, opts) return url("/api/session/" .. encode(id) .. "/prompt", opts) end
function M.abort_url(id, opts) return url("/api/session/" .. encode(id) .. "/interrupt?resume=false", opts) end
function M.rename_session_url(id, opts) return url("/api/session/" .. encode(id), opts) end
M.delete_session_url = M.rename_session_url
function M.event_url(opts) return url("/api/event", opts) end
function M.current_project_url(opts) return url("/api/location", opts) end

-- Credentials travel through stdin, never command arguments, logs or files.
function M.curl_config(opts)
  local password = connections[key(opts)]
  return password and ('user = "opencode:' .. password .. '"\nbasic\n') or ""
end

function M.run(args, cb, opts)
  local command = vim.list_extend({ "curl", "--config", "-" }, vim.list_slice(args, 2))
  return vim.system(command, { text = true, stdin = M.curl_config(opts) }, cb)
end

local function request(method, target, payload, opts, cb)
  opts = opts or {}
  local args = { "curl", "-sS", "-X", method, target, "--max-time", tostring(math.max(1, math.ceil((opts.timeout_ms or 10000) / 1000))), "-w", "\n%{http_code}" }
  if payload then
    vim.list_extend(args, { "-H", "Content-Type: application/json", "--data", vim.json.encode(payload) })
  end
  return M.run(args, function(result)
    local body, status = (result.stdout or ""):match("^(.*)\n(%d%d%d)$")
    result.body, result.status = body or "", tonumber(status)
    local data
    if body and body ~= "" then
      local decoded, value = pcall(vim.json.decode, body)
      if decoded then data = value end
    end
    local ok = result.code == 0 and result.status and result.status >= 200 and result.status < 300
    if ok and body ~= "" and data == nil then ok = false end
    cb(not not ok, data, result)
  end, opts)
end

function M.format_error(result, fallback)
  if not result then return fallback or "opencode request failed" end
  local body = result.body or result.stdout or ""
  if result.status then return "HTTP " .. result.status .. (body ~= "" and (": " .. body) or "") end
  return result.stderr and result.stderr ~= "" and result.stderr or fallback or "opencode request failed"
end

local function session_model(model, variant)
  if type(model) == "string" then
    local provider, id = model:match("^([^/]+)/(.+)$")
    model = { providerID = provider, id = id }
  end
  if not model then return nil end
  return { providerID = model.providerID, id = model.id or model.modelID, variant = variant or model.variant }
end
M._session_model = session_model

function M.create_session(directory, opts, cb)
  return request("POST", M.session_url(opts), {
    title = vim.fn.fnamemodify(directory, ":t"), location = { directory = directory },
    agent = opts.agent, model = session_model(opts.model),
  }, opts, function(ok, data, result)
    local id = data and data.data and data.data.id
    cb(ok and id ~= nil, id, data, result)
  end)
end

function M.configure_session(id, opts, cb)
  local function model()
    if not opts.model then cb(true); return end
    request("POST", M.rename_session_url(id, opts) .. "/model", { model = session_model(opts.model, opts.variant) }, opts, cb)
  end
  if not opts.agent then model(); return end
  request("POST", M.rename_session_url(id, opts) .. "/agent", { agent = opts.agent }, opts, function(ok, data, result)
    if not ok then cb(ok, data, result); return end
    model()
  end)
end

function M.send_message_async(id, text, opts, cb)
  return request("POST", M.prompt_async_url(id, opts), { text = text }, opts, cb)
end

function M.cancel_inbox(id, inbox_id, opts, cb)
  return request("DELETE", M.rename_session_url(id, opts) .. "/inbox/" .. encode(inbox_id), nil, opts, cb)
end

function M.abort_session(id, opts, cb)
  return request("POST", M.abort_url(id, opts), nil, opts, cb)
end

function M.list_sessions(opts, cb)
  local sessions, seen = {}, {}
  local function page(cursor)
    local target = M.session_url(opts) .. "?directory=" .. encode(opts.directory) .. "&limit=100"
    if cursor then target = target .. "&cursor=" .. encode(cursor) end
    return request("GET", target, nil, opts, function(ok, data, result)
      if not ok then cb(false, nil, result); return end
      vim.list_extend(sessions, data.data or {})
      local next_cursor = data.cursor and data.cursor.next
      if next_cursor and next_cursor ~= vim.NIL and not seen[next_cursor] then
        seen[next_cursor] = true
        page(next_cursor)
      else cb(true, { data = sessions }, result) end
    end)
  end
  return page()
end

function M.get_messages(id, opts, cb)
  local messages, seen = {}, {}
  local function page(cursor)
    local target = M.message_url(id, opts) .. "?limit=100" .. (cursor and ("&cursor=" .. encode(cursor)) or "&order=asc")
    request("GET", target, nil, opts, function(ok, data, result)
      if not ok then cb(false, nil, result); return end
      vim.list_extend(messages, data.data or {})
      local next_cursor = data.cursor and data.cursor.next
      if next_cursor and next_cursor ~= vim.NIL and not seen[next_cursor] then seen[next_cursor] = true; page(next_cursor)
      else cb(true, messages, result) end
    end)
  end
  page()
end

function M.fork_session(id, opts, cb)
  return request("POST", M.rename_session_url(id, opts) .. "/fork", vim.empty_dict(), opts, function(ok, data, result)
    cb(ok, data and data.data, result)
  end)
end

function M.get_session(id, opts, cb)
  return request("GET", M.rename_session_url(id, opts), nil, opts, function(ok, data, result) cb(ok, data and data.data, result) end)
end

function M.rename_session(id, title, opts, cb)
  return request("PATCH", M.rename_session_url(id, opts), { title = title }, opts, cb)
end

function M.delete_session(id, opts, cb)
  return request("DELETE", M.delete_session_url(id, opts), nil, opts, cb)
end

function M.extract_message_role_text(message)
  if message.type == "user" then return "user", message.text or "" end
  if message.type == "assistant" then
    local text = {}
    for _, part in ipairs(message.content or {}) do
      if part.type == "text" then table.insert(text, part.text or "") end
    end
    return "assistant", table.concat(text, "")
  end
  return nil, ""
end

function M.to_chat_messages(messages)
  local out = {}
  for _, message in ipairs(messages or {}) do
    local role, text = M.extract_message_role_text(message)
    if role and text ~= "" then table.insert(out, { role = role:gsub("^%l", string.upper), text = text }) end
  end
  return out
end

return M
