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

function M.state()
  return state
end

local function remember_session(session_id, data)
  if not session_id then
    return
  end
  state.sessions[session_id] = vim.tbl_extend("force", state.sessions[session_id] or {}, {
    id = session_id,
    title = (data and (data.title or (data.data and data.data.title))) or session_id,
    model = config.current_model(),
  })
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

function M.send(text, startpath, cb)
  local cfg = config.get()
  M.ensure_started(startpath, function(ok, current, err)
    if not ok then
      cb(false, nil, err)
      return
    end
    local model = config.current_model()
    active = client.send_message(current.session_id, text, { host = cfg.host, port = current.port, model = model, agent = cfg.agent, api_style = current.api_style }, function(sent, data, result, reply)
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
    client.list_sessions({ host = config.get().host, port = state.port }, function(list_ok, data, result)
      local sessions = {}
      local raw = data and (data.data or data)
      if list_ok and type(raw) == "table" then
        for _, item in ipairs(raw) do
          if type(item) == "table" and item.id then
            table.insert(sessions, item)
            remember_session(item.id, item)
          end
        end
      end
      if #sessions == 0 then
        for _, item in pairs(state.sessions) do
          table.insert(sessions, item)
        end
      end
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

return M
