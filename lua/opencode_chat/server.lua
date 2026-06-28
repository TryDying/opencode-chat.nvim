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
}

local function job_running(job_id)
  return job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1
end

function M.state()
  return state
end

function M.ensure_started(startpath, cb)
  local cfg = config.get()

  if state.started and job_running(state.job_id) then
    if state.session_id then
      cb(true, state)
      return
    end
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

      client.create_session(state.root, { host = cfg.host, port = state.port, agent = cfg.agent, model = cfg.model, variant = cfg.variant }, function(created, session_id, _data, create_result, api_style)
        if not created then
          cb(false, state, client.format_error(create_result, "failed to create session"))
          return
        end
        state.session_id = session_id
        state.api_style = api_style
        cb(true, state)
      end)
    end)
  end)
end

function M.send(text, startpath, cb)
  local cfg = config.get()
  M.ensure_started(startpath, function(ok, current, err)
    if not ok then
      cb(false, nil, err)
      return
    end
    active = client.send_message(current.session_id, text, { host = cfg.host, port = current.port, model = cfg.model, agent = cfg.agent, variant = cfg.variant, api_style = current.api_style }, function(sent, data, result, reply)
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
end

function M.new_session(cb)
  M.stop()
  M.ensure_started(nil, cb or function() end)
end

return M
