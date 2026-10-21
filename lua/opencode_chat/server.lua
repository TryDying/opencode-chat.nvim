local config = require("opencode_chat.config")
local root = require("opencode_chat.root")
local client = require("opencode_chat.client")
local chat = require("opencode_chat.chat")
local debug = require("opencode_chat.debug")

local M = {}
local active = nil
local owned = {}
local workspace_sessions = {}
local pending = nil
local creating = {}

local state = {
  root = nil,
  port = nil,
  job_id = nil,
  session_id = nil,
  project_id = nil,
  started = false,
  ready = false,
  starting = false,
  waiters = {},
  job_pid = nil,
  job_stdout = {},
  job_stderr = {},
  job_exit_code = nil,
  job_exit_type = nil,
  sessions = {},
}

local function job_running(job_id)
  return job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function append_tail(target, data)
  for _, line in ipairs(data or {}) do
    if line ~= "" then
      table.insert(target, line)
    end
  end
  while #target > 80 do
    table.remove(target, 1)
  end
end

local function join_tail(lines)
  return table.concat(lines or {}, "\n")
end

local function job_summary(message)
  local parts = { message or "opencode server failed" }
  if state.job_exit_code ~= nil then
    table.insert(parts, "exit_code=" .. tostring(state.job_exit_code))
  end
  if state.job_exit_type ~= nil then
    table.insert(parts, "exit_type=" .. tostring(state.job_exit_type))
  end
  if state.job_pid ~= nil then
    table.insert(parts, "pid=" .. tostring(state.job_pid))
  end
  if state.root ~= nil then
    table.insert(parts, "cwd=" .. tostring(state.root))
  end
  local stderr = join_tail(state.job_stderr)
  if stderr ~= "" then
    table.insert(parts, "stderr:\n" .. stderr)
  end
  local stdout = join_tail(state.job_stdout)
  if stdout ~= "" then
    table.insert(parts, "stdout:\n" .. stdout)
  end
  return table.concat(parts, "\n")
end

local function job_pid(job_id)
  if not job_id then
    return nil
  end
  local ok, pid = pcall(vim.fn.jobpid, job_id)
  if ok and type(pid) == "number" and pid > 0 then
    return pid
  end
  return nil
end

local function normalize_path(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  return vim.fs.normalize(value)
end

local function session_project_id(session)
  if type(session) ~= "table" then return nil end
  return session.projectID or session.projectId or session.project_id
    or (type(session.project) == "table" and (session.project.id or session.project.projectID or session.project.projectId or session.project.project_id))
end

local function session_directory(session)
  if type(session) ~= "table" then return nil end
  return (session.location and session.location.directory) or session.directory or session.path or session.worktree or session.cwd
    or (type(session.project) == "table" and (session.project.directory or session.project.path or session.project.worktree or session.project.cwd))
end

local function session_parent_id(session)
  if type(session) ~= "table" then return nil end
  return session.parentID or session.parentId or session.parent_id or session.parentSessionID or session.parentSessionId or session.parent_session_id
    or (type(session.parent) == "table" and (session.parent.id or session.parent.sessionID or session.parent.sessionId or session.parent.session_id))
end

local function session_kind(session)
  if type(session) ~= "table" then return nil end
  return session.kind or session.type or session.category or session.source
    or (type(session.metadata) == "table" and (session.metadata.kind or session.metadata.type or session.metadata.category or session.metadata.source))
end

local function session_title(session)
  if type(session) ~= "table" then return "" end
  return tostring(session.title or session.name or "")
end

local function session_is_user_visible(session)
  if type(session) ~= "table" then return false end
  if session_parent_id(session) then return false end
  local kind = session_kind(session)
  if type(kind) == "string" and kind:lower():match("subagent") then return false end
  if session_title(session):match("%(@[^%)]- subagent%)") then return false end
  return true
end

function M.state()
  return state
end

local function remember_session(session_id, data)
  if not session_id then return end
  local raw = data and (data.data or data) or {}
  state.sessions[session_id] = vim.tbl_extend("force", state.sessions[session_id] or {}, {
    id = session_id,
    title = raw.title or session_id,
    projectID = session_project_id(raw) or state.project_id,
    directory = session_directory(raw) or state.root,
    model = config.current_model(),
  })
end

local function session_matches_project(session)
  if type(session) ~= "table" then return false end
  local session_dir = normalize_path(session_directory(session))
  local current_root = normalize_path(state.root)
  if session_dir ~= nil and current_root ~= nil then
    return session_dir == current_root
  end
  local project_id = session_project_id(session)
  return state.project_id ~= nil and project_id == state.project_id
end

local function session_list_payload(raw)
  if type(raw) ~= "table" then return {} end
  local payload = raw.data or raw
  if type(payload) ~= "table" then return {} end
  if payload.sessions then payload = payload.sessions
  elseif payload.items then payload = payload.items
  elseif payload.list then payload = payload.list end
  if type(payload) ~= "table" then return {} end
  return payload
end

local function collect_sessions(raw, filter_project)
  local sessions = {}
  if type(raw) ~= "table" then return sessions end
  for _, item in pairs(session_list_payload(raw)) do
    local id = type(item) == "table" and (item.id or item.sessionID or item.sessionId or item.session_id)
    if type(item) == "table" and id then item.id = id end
    if type(item) == "table" and item.id and session_is_user_visible(item) and (not filter_project or session_matches_project(item)) then
      table.insert(sessions, item)
      remember_session(item.id, item)
    end
  end
  return sessions
end

local function stop_active_request()
  if active then
    if active.cancel then active.cancel()
    elseif active.kill then pcall(function() active:kill(15) end) end
    active = nil
  end
end

local function sync_abort_session(session_id, port_value)
  if not session_id or not port_value then return false end
  local target = client.abort_url(session_id, { host = config.get().host, port = port_value })
  local opts = { host = config.get().host, port = port_value }
  local response = vim.system({ "curl", "--config", "-", "-sS", "-X", "POST", target, "--max-time", "2", "-w", "\n%{http_code}" }, { text = true, stdin = client.curl_config(opts) }):wait()
  local result = response.stdout
  local status = tostring(result or ""):match("(%d%d%d)%s*$")
  return response.code == 0 and status and tonumber(status) >= 200 and tonumber(status) < 300
end

local function flush_waiters(ok, err)
  local waiters = state.waiters
  state.waiters = {}
  debug.log("server", "flush_waiters", { ok = ok, err = err, waiters = #waiters, ready = state.ready, starting = state.starting, port = state.port, root = state.root })
  for _, waiter in ipairs(waiters) do
    vim.schedule(function() waiter(ok, state, err) end)
  end
end

function M.ensure_server(startpath, cb)
  local cfg = config.get()
  debug.log("server", "ensure_server", { startpath = startpath, started = state.started, ready = state.ready, starting = state.starting, job_id = state.job_id, running = job_running(state.job_id), waiters = #state.waiters, root = state.root, port = state.port })

  if state.ready and state.started and job_running(state.job_id) then
    cb(true, state)
    return
  elseif state.starting and state.started and job_running(state.job_id) then
    table.insert(state.waiters, cb)
    return
  else
    state.root = root.find(startpath)
    state.port = nil
    state.ready = false
    state.starting = true
    state.waiters = { cb }
    state.job_pid = nil
    state.job_stdout = {}
    state.job_stderr = {}
    state.job_exit_code = nil
    state.job_exit_type = nil
    local random = io.open("/dev/urandom", "rb")
    local bytes = random and random:read(32)
    if random then random:close() end
    if not bytes or #bytes ~= 32 then
      state.starting = false
      flush_waiters(false, "secure random source unavailable")
      return
    end
    local password = bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end)
    local cmd = { cfg.command, "serve", "--stdio", "--port", tostring(cfg.port or 0), "--hostname", cfg.host }
    local stdout = ""
    debug.log("server", "start_job", { cmd = cmd, cwd = state.root })
    local job_id
    job_id = vim.fn.jobstart(cmd, {
      cwd = state.root,
      env = { OPENCODE_PASSWORD = password },
      stdin = "pipe",
      stdout_buffered = false,
      stderr_buffered = false,
      on_stdout = function(_, data)
        if state.job_id ~= job_id then return end
        stdout = stdout .. table.concat(data, "\n")
        while stdout:find("\n", 1, true) do
          local line, rest = stdout:match("^([^\n]*)\n(.*)$")
          stdout = rest
          local decoded, ready = pcall(vim.json.decode, line)
          if decoded and type(ready) == "table" and type(ready.url) == "string" and state.starting then
            local host, port_value = ready.url:match("^http://([^/:]+):(%d+)/?$")
            if not host or host ~= cfg.host then
              state.starting = false
              flush_waiters(false, "invalid private server ready URL")
              pcall(vim.fn.chanclose, job_id, "stdin")
              return
            end
            state.port = tonumber(port_value)
            client.connect({ host = cfg.host, port = state.port }, password)
            state.ready, state.starting = true, false
            flush_waiters(true)
          elseif not decoded then append_tail(state.job_stdout, { line }) end
        end
      end,
      on_stderr = function(_, data)
        if state.job_id ~= job_id then return end
        append_tail(state.job_stderr, data)
      end,
      on_exit = function(_, exit_code, exit_type)
        local was_starting = state.starting
        local matches_current = state.job_id == job_id
        debug.log("server", "job_exit", { job_id = job_id, pid = state.job_pid, root = state.root, port = state.port, starting = state.starting, waiters = #state.waiters, exit_code = exit_code, exit_type = exit_type, current = matches_current })
        if matches_current then
          state.job_exit_code = exit_code
          state.job_exit_type = exit_type
          state.started = false
          state.ready = false
          state.starting = false
          state.job_id = nil
          state.session_id = nil
          if state.port then client.disconnect({ host = cfg.host, port = state.port }) end
          workspace_sessions = {}
          if was_starting then
            flush_waiters(false, job_summary("opencode server exited before becoming ready"))
          end
        end
      end,
    })
    state.job_id = job_id
    if state.job_id <= 0 then
      state.starting = false
      flush_waiters(false, "failed to start opencode serve")
      return
    end
    state.job_pid = job_pid(state.job_id)
    state.started = true
    debug.log("server", "start_job.ok", { job_id = state.job_id, pid = state.job_pid, root = state.root, port = state.port })
  end

  local starting_job = state.job_id
  vim.defer_fn(function()
    if state.job_id == starting_job and state.starting then
      state.starting = false
      flush_waiters(false, job_summary("opencode private server readiness timed out"))
      pcall(vim.fn.chanclose, starting_job, "stdin")
      pcall(vim.fn.jobstop, starting_job)
    end
  end, cfg.startup_timeout_ms)
end

function M.create_session(cb)
  if vim.in_fast_event() then
    vim.schedule(function() M.create_session(cb) end)
    return
  end
  local cfg = config.get()
  local directory, job = state.root, state.job_id
  client.create_session(directory, { host = cfg.host, port = state.port, agent = cfg.agent, model = config.current_model() },
    function(created, session_id, data, create_result)
      if state.job_id ~= job then cb(false, state, "private server stopped during session creation"); return end
      debug.log("server", "create_session.done", { created = created, session_id = session_id, status = create_result and create_result.status, error = create_result and create_result.error })
      if not created then
        cb(false, state, client.format_error(create_result, "failed to create session"))
        return
      end
      state.session_id = session_id
      owned[session_id] = true
      state.root = directory
      workspace_sessions[directory] = session_id
      remember_session(session_id, data)
      cb(true, state)
    end)
end

function M.ensure_started(startpath, cb)
  local directory = root.find(startpath)
  M.ensure_server(startpath, function(ok, current, err)
    if not ok then cb(false, current, err); return end
    local function deliver(id, failure)
      if not id then cb(false, current, failure); return end
      state.root, state.session_id = directory, id
      cb(true, vim.tbl_extend("force", current, { root = directory, session_id = id }))
    end
    if workspace_sessions[directory] then deliver(workspace_sessions[directory]); return end
    if creating[directory] then table.insert(creating[directory], deliver); return end
    local waiters = { deliver }
    creating[directory] = waiters
    local cfg, starting_job = config.get(), state.job_id
    client.create_session(directory, { host = config.get().host, port = current.port, agent = cfg.agent, model = config.current_model() }, function(created, id, data, result)
      if state.job_id ~= starting_job then
        for _, waiter in ipairs(waiters) do waiter(nil, "private server stopped during session creation") end
        return
      end
      creating[directory] = nil
      if not created then
        -- Each caller receives the failure; never send using another root.
        for _, waiter in ipairs(waiters) do waiter(nil, client.format_error(result, "session creation failed")) end
        return
      end
      owned[id], workspace_sessions[directory] = true, id
      remember_session(id, data)
      for _, waiter in ipairs(waiters) do waiter(id) end
    end)
  end)
end

function M.send(text, project_root, callbacks)
  callbacks = callbacks or {}
  local cfg = config.get()
  if pending or (active and active.is_busy and active.is_busy()) then
    if callbacks.on_error then callbacks.on_error("opencode main request is already active") end
    return nil
  end
  local cancelled, handle = false, nil
  local proxy
  proxy = {
    cancel = function(cb)
      cancelled = true
      if pending == proxy then pending = nil end
      if handle then handle.cancel(cb)
      else
        if callbacks.on_cancelled then callbacks.on_cancelled() end
        if cb then cb(true) end
      end
    end,
  }
  pending = proxy
  M.ensure_started(project_root, function(ok, current, err)
    if cancelled then return end
    if not ok then
      if pending == proxy then pending = nil end
      if callbacks.on_error then callbacks.on_error(err or "server not ready") end
      return
    end
    local model = config.current_model()
    handle = chat.send({
      session_id = current.session_id,
      host = cfg.host,
      port = current.port,
      directory = current.root,
      text = text,
      model = { providerID = model.providerID, modelID = model.modelID },
      agent = cfg.agent,
      variant = model.variant,
    }, callbacks)
    active = handle
    pending = nil
  end)
  return proxy
end

function M.create_ephemeral_session(startpath, cb)
  local cfg = config.get()
  local directory = root.find(startpath)
  M.ensure_server(startpath, function(ok, current, err)
    if not ok then cb(false, nil, err); return end
    local job, port_value = state.job_id, current.port
    client.create_session(directory, { host = cfg.host, port = current.port, agent = cfg.agent, model = config.current_model() },
      function(created, session_id, _data, create_result)
        if state.job_id ~= job then cb(false, nil, "private server stopped during Quick session creation"); return end
        debug.log("server", "create_ephemeral_session.done", { created = created, session_id = session_id, status = create_result and create_result.status, error = create_result and create_result.error })
        if not created then
          cb(false, nil, client.format_error(create_result, "failed to create quick session"))
          return
        end
        owned[session_id] = true
        cb(true, { root = directory, port = port_value, session_id = session_id, project_id = current.project_id })
      end)
  end)
end

function M.send_ephemeral(session, text, callbacks)
  callbacks = callbacks or {}
  if not session or not session.session_id then
    if callbacks.on_error then callbacks.on_error("quick session is missing") end
    return nil
  end
  local cfg = config.get()
  local model = config.current_model()
  local handle = chat.send({
    session_id = session.session_id,
    host = cfg.host,
    port = session.port,
    directory = session.root,
    text = text,
    model = { providerID = model.providerID, modelID = model.modelID },
    agent = cfg.agent,
    variant = model.variant,
  }, callbacks)
  return handle
end

function M.abort_ephemeral(session, cb)
  if not session or not session.session_id then
    if cb then cb(false, "quick session is missing") end
    return
  end
  client.abort_session(session.session_id, { host = config.get().host, port = session.port }, function(ok, _data, result)
    if cb then cb(ok, ok and "cancelled" or client.format_error(result, "quick cancel failed")) end
  end)
end

function M.delete_ephemeral(session, cb)
  if not session or not session.session_id then
    if cb then cb(true) end
    return
  end
  client.delete_session(session.session_id, { host = config.get().host, port = session.port, directory = session.root }, function(ok, data, result)
    if cb then cb(ok, data, ok and nil or client.format_error(result, "failed to delete quick session")) end
  end)
end

function M.delete_ephemeral_sync(session)
  if not session or not session.session_id then return true end
  local target = client.delete_session_url(session.session_id, { host = config.get().host, port = session.port, directory = session.root })
  local response = vim.system({ "curl", "--config", "-", "-sS", "-X", "DELETE", target, "--max-time", "2", "-w", "\n%{http_code}" }, { text = true, stdin = client.curl_config({ host = config.get().host, port = session.port }) }):wait()
  local result = response.stdout
  local status = tostring(result or ""):match("(%d%d%d)%s*$")
  return response.code == 0 and status and tonumber(status) >= 200 and tonumber(status) < 300
end

function M.cancel(cb)
  if pending then pending.cancel(cb); pending = nil; return end
  if active then active.cancel(cb); return end
  if state.session_id then
    client.abort_session(state.session_id, { host = config.get().host, port = state.port }, function(ok, _data, result)
      if cb then cb(ok, ok and "cancelled" or client.format_error(result, "cancel failed")) end
    end)
  else
    if cb then cb(false, "no active session to cancel") end
  end
end

function M.stop()
  stop_active_request()
  if state.session_id and state.port then
    sync_abort_session(state.session_id, state.port)
  end
  local stopped_job = state.job_id
  local stopped_pid = state.job_pid or job_pid(stopped_job)
  if job_running(stopped_job) then
    debug.log("server", "stop.begin", { job_id = stopped_job, pid = stopped_pid, root = state.root, port = state.port })
    pcall(vim.fn.chanclose, stopped_job, "stdin")
    local result = vim.fn.jobwait({ stopped_job }, 1000)[1]
    if result == -1 and stopped_pid then
      pcall(vim.fn.system, { "kill", "-TERM", tostring(stopped_pid) })
      result = vim.fn.jobwait({ stopped_job }, 1000)[1]
    end
    if result == -1 and stopped_pid then
      pcall(vim.fn.system, { "kill", "-KILL", tostring(stopped_pid) })
    end
  end
  if state.port then client.disconnect({ host = config.get().host, port = state.port }) end
  owned, workspace_sessions, creating, pending = {}, {}, {}, nil
  state.waiters = {}
  state.root = nil
  state.port = nil
  state.job_id = nil
  state.job_pid = nil
  state.session_id = nil
  state.project_id = nil
  state.started = false
  state.ready = false
  state.starting = false
  state.job_stdout = {}
  state.job_stderr = {}
  state.job_exit_code = nil
  state.job_exit_type = nil
  state.sessions = {}
end

function M.new_session(cb)
  local directory = root.find()
  M.ensure_server(directory, function(ok, _current, err)
    if not ok then if cb then cb(false, state, err) end; return end
    state.session_id = nil
    state.root = directory
    M.create_session(cb or function() end)
  end)
end

function M.list_sessions(cb)
  local directory = root.find()
  M.ensure_server(directory, function(ok, _current, err)
    if not ok then cb(false, {}, err); return end
    state.root, state.session_id = directory, workspace_sessions[directory]
    local opts = { host = config.get().host, port = state.port, directory = directory }
    local function cached_sessions()
      local sessions = {}
      for _, item in pairs(state.sessions) do
        if session_matches_project(item) then table.insert(sessions, item) end
      end
      return sessions
    end
    client.list_sessions(opts, function(list_ok, data, result)
      local sessions = collect_sessions(data, true)
      if #sessions == 0 then sessions = cached_sessions() end
      table.sort(sessions, function(a, b)
        return tostring(a.title or a.id) < tostring(b.title or b.id)
      end)
      cb(#sessions > 0 or list_ok, sessions, list_ok and nil or client.format_error(result, "failed to list sessions"))
    end)
  end)
end

function M.select_session(session_id, cb)
  if not session_id or session_id == "" then
    cb(false, nil, "session id is required")
    return
  end
  M.ensure_server(nil, function(ok, _current, err)
    if not ok then cb(false, nil, err); return end
    local opts = { host = config.get().host, port = state.port }
    local function load(id, info)
      client.get_messages(id, opts, function(history_ok, data, result)
        if not history_ok then
          cb(false, nil, client.format_error(result, "failed to load session messages"))
          return
        end
        state.session_id = id
        owned[id] = true
        workspace_sessions[state.root] = id
        remember_session(id, info or { id = id })
        cb(true, data)
      end)
    end
    client.get_session(session_id, opts, function(found, info, result)
      if not found then cb(false, nil, client.format_error(result, "session not found")); return end
      if not session_matches_project(info) then cb(false, nil, "session belongs to another workspace"); return end
      if owned[session_id] then load(session_id, info); return end
      client.fork_session(session_id, opts, function(forked, fork, fork_result)
        if not forked or not fork then cb(false, nil, client.format_error(fork_result, "failed to fork history")); return end
        owned[fork.id] = true
        load(fork.id, fork)
      end)
    end)
  end)
end

function M.rename_session(session_id, title, cb)
  if not session_id or session_id == "" then cb(false, nil, "session id is required"); return end
  if not title or title == "" then cb(false, nil, "session title is required"); return end
  M.ensure_server(nil, function(ok, _current, err)
    if not ok then cb(false, nil, err); return end
    client.rename_session(session_id, title, { host = config.get().host, port = state.port }, function(rename_ok, data, result)
      if not rename_ok then
        cb(false, nil, client.format_error(result, "failed to rename session"))
        return
      end
      remember_session(session_id, data or { id = session_id, title = title })
      if state.sessions[session_id] then state.sessions[session_id].title = title end
      cb(true, data)
    end)
  end)
end

function M.delete_session(session_id, cb)
  if not session_id or session_id == "" then cb(false, nil, "session id is required"); return end
  M.ensure_server(nil, function(ok, _current, err)
    if not ok then cb(false, nil, err); return end
    client.delete_session(session_id, { host = config.get().host, port = state.port, directory = state.root }, function(delete_ok, data, result)
      if not delete_ok then
        cb(false, nil, client.format_error(result, "failed to delete session"))
        return
      end
      state.sessions[session_id] = nil
      if state.session_id == session_id then state.session_id = nil end
      for directory, id in pairs(workspace_sessions) do
        if id == session_id then workspace_sessions[directory] = nil end
      end
      cb(true, data)
    end)
  end)
end

return M
