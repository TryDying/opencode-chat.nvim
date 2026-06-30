local config = require("opencode_chat.config")
local port = require("opencode_chat.port")
local root = require("opencode_chat.root")
local client = require("opencode_chat.client")

local M = {}
local active = nil

local state = {
  root = nil,
  port = nil,
  job_id = nil,
  session_id = nil,
  project_id = nil,
  api_style = nil,
  started = false,
  sessions = {},
}

local function job_running(job_id)
  return job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function normalize_path(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  return vim.fs.normalize(value)
end

local function session_project_id(session)
  if type(session) ~= "table" then
    return nil
  end
  return session.projectID
    or session.projectId
    or session.project_id
    or (type(session.project) == "table" and (session.project.id or session.project.projectID or session.project.projectId or session.project.project_id))
end

local function session_directory(session)
  if type(session) ~= "table" then
    return nil
  end
  return session.directory
    or session.path
    or session.worktree
    or session.cwd
    or (type(session.project) == "table" and (session.project.directory or session.project.path or session.project.worktree or session.project.cwd))
end

function M.state()
  return state
end

local function remember_session(session_id, data)
  if not session_id then
    return
  end
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
  if type(session) ~= "table" then
    return false
  end
  local session_dir = normalize_path(session_directory(session))
  local current_root = normalize_path(state.root)
  if session_dir ~= nil and current_root ~= nil then
    return session_dir == current_root
  end
  local project_id = session_project_id(session)
  return state.project_id ~= nil and project_id == state.project_id
end

local function session_list_payload(raw)
  if type(raw) ~= "table" then
    return {}
  end
  local payload = raw.data or raw
  if type(payload) ~= "table" then
    return {}
  end
  if payload.sessions then
    payload = payload.sessions
  elseif payload.items then
    payload = payload.items
  elseif payload.list then
    payload = payload.list
  end
  if type(payload) ~= "table" then
    return {}
  end
  return payload
end

local function collect_sessions(raw, filter_project)
  local sessions = {}
  if type(raw) ~= "table" then
    return sessions
  end
  for _, item in pairs(session_list_payload(raw)) do
    local id = type(item) == "table" and (item.id or item.sessionID or item.sessionId or item.session_id)
    if type(item) == "table" and id then
      item.id = id
    end
    if type(item) == "table" and item.id and (not filter_project or session_matches_project(item)) then
      table.insert(sessions, item)
      remember_session(item.id, item)
    end
  end
  return sessions
end

local function merge_sessions(base, extra)
  local seen = {}
  local out = {}
  for _, list in ipairs({ base or {}, extra or {} }) do
    for _, session in ipairs(list) do
      if session.id and not seen[session.id] then
        seen[session.id] = true
        table.insert(out, session)
      end
    end
  end
  return out
end

function M.ensure_server(startpath, cb)
  local cfg = config.get()

  if state.started and job_running(state.job_id) then
    cb(true, state)
    return
  else
    state.root = root.find(startpath)
    state.port = cfg.port or port.pick(cfg.host)
    local cmd = { cfg.command, "serve", "--port", tostring(state.port), "--hostname", cfg.host }
    state.job_id = vim.fn.jobstart(cmd, {
      cwd = state.root,
      stdout_buffered = false,
      stderr_buffered = false,
      on_exit = function()
        state.started = false
        state.job_id = nil
        state.session_id = nil
      end,
    })
    if state.job_id <= 0 then
      cb(false, state, "failed to start opencode serve")
      return
    end
    state.started = true
  end

  client.wait_until_ready({ host = cfg.host, port = state.port, timeout_ms = cfg.startup_timeout_ms }, function(ok, result)
    if not ok then
      cb(false, state, result and (result.stderr or result.stdout) or "opencode server not ready")
      return
    end
    client.get_project_id(state.root, { host = cfg.host, port = state.port }, function(_project_ok, project_id)
      state.project_id = project_id
      cb(true, state)
    end)
  end)
end

function M.create_session(cb)
  local cfg = config.get()
  client.create_session(state.root, { host = cfg.host, port = state.port, agent = cfg.agent, model = config.current_model() }, function(created, session_id, data, create_result, api_style)
    if not created then
      cb(false, state, client.format_error(create_result, "failed to create session"))
      return
    end
    state.session_id = session_id
    state.api_style = api_style
    remember_session(session_id, data)
    cb(true, state)
  end)
end

function M.ensure_started(startpath, cb)
  M.ensure_server(startpath, function(ok, current, err)
    if not ok then
      cb(false, current, err)
      return
    end
    if current.session_id then
      cb(true, current)
      return
    end
    M.create_session(cb)
  end)
end

local function event_session_id(event)
  local props = event and event.properties
  if type(props) ~= "table" then
    return nil
  end
  return props.sessionID or props.sessionId or props.session_id or (props.session and props.session.id) or (props.message and props.message.sessionID)
end

local function text_from_event(event)
  if type(event) ~= "table" then
    return "", false
  end
  if event.type ~= "message.part.updated" and event.type ~= "message.part.delta" then
    return "", false
  end
  local part = event.properties and event.properties.part
  if type(part) == "table" and part.type ~= nil and part.type ~= "text" then
    return "", false
  end
  if type(part) == "table" and type(part.text) == "string" then
    return part.text, event.type == "message.part.delta"
  end
  local props = event.properties or {}
  if type(props.text) == "string" then
    return props.text, event.type == "message.part.delta"
  end
  if type(props.delta) == "string" then
    return props.delta, true
  end
  return "", false
end

function M.send(text, startpath, cb, events)
  local cfg = config.get()
  M.ensure_started(startpath, function(ok, current, err)
    if not ok then
      cb(false, nil, err)
      return
    end
    if vim.in_fast_event() then
      vim.schedule(function()
        M.send(text, startpath, cb, events)
      end)
      return
    end
    local model = config.current_model()
    local streamed_text = ""
    local stream = client.subscribe_events({ host = cfg.host, port = current.port }, function(event)
      local session_id = event_session_id(event)
      if session_id and session_id ~= current.session_id then
        return
      end
      local text_delta, append = text_from_event(event)
      if text_delta ~= "" and events and events.on_delta then
        if append then
          streamed_text = streamed_text .. text_delta
        else
          streamed_text = text_delta
        end
        events.on_delta(streamed_text)
      end
    end)
    local send_handle
    local function cancel_stream()
      if stream then
        stream.cancel()
        stream = nil
      end
    end
    send_handle = client.send_message(current.session_id, text, { host = cfg.host, port = current.port, model = model, agent = cfg.agent, api_style = current.api_style }, function(sent, data, result, reply)
      cancel_stream()
      active = nil
      if not sent then
        cb(false, nil, client.format_error(result, "prompt failed"))
        return
      end

      if reply and reply ~= "" then
        cb(true, reply, data)
        return
      end

      active = client.wait_for_assistant(current.session_id, { host = cfg.host, port = current.port, project_id = current.project_id, timeout_ms = cfg.startup_timeout_ms }, function(found, assistant_text, history, history_result)
        active = nil
        if found then
          cb(true, assistant_text, history)
          return
        end
        cb(false, nil, client.format_error(history_result, "assistant response not found"))
      end)
    end)
    active = {
      cancel = function()
        cancel_stream()
        if send_handle and send_handle.kill then
          pcall(function()
            send_handle:kill(15)
          end)
        elseif send_handle and send_handle.cancel then
          send_handle.cancel()
        end
      end
    }
  end)
end

function M.cancel(cb)
  if active then
    if active.cancel then
      active.cancel()
    elseif active.kill then
      pcall(function()
        active:kill(15)
      end)
    end
    active = nil
  end

  if state.session_id and state.api_style == "session" then
    return client.abort_session(state.session_id, { host = config.get().host, port = state.port }, function(ok, _data, result)
      if ok then
        state.session_id = nil
        state.api_style = nil
      end
      if cb then
        cb(ok, ok and "cancelled" or client.format_error(result, "cancel failed"))
      end
    end)
  end

  if cb then
    cb(false, "backend abort is unavailable for this session")
  end
end

function M.stop()
  M.cancel()
  if job_running(state.job_id) then
    vim.fn.jobstop(state.job_id)
  end
  state.root = nil
  state.port = nil
  state.job_id = nil
  state.session_id = nil
  state.project_id = nil
  state.api_style = nil
  state.started = false
  state.sessions = {}
end

function M.new_session(cb)
  M.ensure_server(nil, function(ok, _current, err)
    if not ok then
      if cb then
        cb(false, state, err)
      end
      return
    end
    state.session_id = nil
    M.create_session(cb or function() end)
  end)
end

function M.list_sessions(cb)
  M.ensure_server(nil, function(ok, _current, err)
    if not ok then
      cb(false, {}, err)
      return
    end
    local opts = { host = config.get().host, port = state.port }
    local function cached_sessions()
      local sessions = {}
      for _, item in pairs(state.sessions) do
        if session_matches_project(item) then
          table.insert(sessions, item)
        end
      end
      return sessions
    end
    local function finish_with_cache(sessions, list_ok, result)
      if #sessions == 0 then
        sessions = cached_sessions()
      end
      table.sort(sessions, function(a, b)
        return tostring(a.title or a.id) < tostring(b.title or b.id)
      end)
      cb(#sessions > 0 or list_ok, sessions, list_ok and nil or client.format_error(result, "failed to list sessions"))
    end

    if state.project_id then
      client.list_project_sessions(state.project_id, opts, function(project_ok, project_data, project_result)
        local project_sessions = collect_sessions(project_data, true)
        if project_ok and #project_sessions > 0 then
          finish_with_cache(merge_sessions(project_sessions, cached_sessions()), true, project_result)
          return
        end
        client.list_sessions(opts, function(list_ok, data, result)
          local global_sessions = collect_sessions(data, true)
          finish_with_cache(merge_sessions(project_sessions, global_sessions), list_ok or project_ok, list_ok and result or project_result)
        end)
      end)
      return
    end

    client.list_sessions(opts, function(list_ok, data, result)
      finish_with_cache(collect_sessions(data, true), list_ok, result)
    end)
  end)
end

function M.select_session(session_id, cb)
  if not session_id or session_id == "" then
    cb(false, nil, "session id is required")
    return
  end
  M.ensure_server(nil, function(ok, _current, err)
    if not ok then
      cb(false, nil, err)
      return
    end
    state.session_id = session_id
    state.api_style = "session"
    remember_session(session_id, { id = session_id })
    client.get_messages(session_id, { host = config.get().host, port = state.port }, function(history_ok, data, result)
      if not history_ok then
        cb(false, nil, client.format_error(result, "failed to load session messages"))
        return
      end
      cb(true, data)
    end)
  end)
end

function M.rename_session(session_id, title, cb)
  if not session_id or session_id == "" then
    cb(false, nil, "session id is required")
    return
  end
  if not title or title == "" then
    cb(false, nil, "session title is required")
    return
  end
  M.ensure_server(nil, function(ok, _current, err)
    if not ok then
      cb(false, nil, err)
      return
    end
    client.rename_session(session_id, title, { host = config.get().host, port = state.port }, function(rename_ok, data, result)
      if not rename_ok then
        cb(false, nil, client.format_error(result, "failed to rename session"))
        return
      end
      remember_session(session_id, data or { id = session_id, title = title })
      if state.sessions[session_id] then
        state.sessions[session_id].title = title
      end
      cb(true, data)
    end)
  end)
end

function M.delete_session(session_id, cb)
  if not session_id or session_id == "" then
    cb(false, nil, "session id is required")
    return
  end
  M.ensure_server(nil, function(ok, _current, err)
    if not ok then
      cb(false, nil, err)
      return
    end
    client.delete_session(session_id, { host = config.get().host, port = state.port, directory = state.root }, function(delete_ok, data, result)
      if not delete_ok then
        cb(false, nil, client.format_error(result, "failed to delete session"))
        return
      end
      state.sessions[session_id] = nil
      if state.session_id == session_id then
        state.session_id = nil
        state.api_style = nil
      end
      cb(true, data)
    end)
  end)
end

return M
