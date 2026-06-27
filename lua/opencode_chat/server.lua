local config = require("opencode_chat.config")
local port = require("opencode_chat.port")
local root = require("opencode_chat.root")
local client = require("opencode_chat.client")

local M = {}

local state = {
  root = nil,
  port = nil,
  job_id = nil,
  session_id = nil,
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
    client.create_session(state.root, { host = cfg.host, port = state.port }, function(created, session_id, _data, create_result)
      if not created then
        cb(false, state, create_result and (create_result.stderr or create_result.stdout) or "failed to create session")
        return
      end
      state.session_id = session_id
      cb(true, state)
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
    client.send_prompt(current.session_id, text, { host = cfg.host, port = current.port, model = cfg.model }, function(sent, data, result, reply)
      if not sent then
        cb(false, nil, result and (result.stderr or result.stdout) or "prompt failed")
        return
      end

      client.wait_for_assistant(current.session_id, { host = cfg.host, port = current.port, timeout_ms = cfg.startup_timeout_ms }, function(found, assistant_text, history, history_result)
        if found then
          cb(true, assistant_text, history)
          return
        end

        if reply ~= "" and reply ~= text then
          cb(true, reply, data)
          return
        end

        cb(false, nil, history_result and (history_result.stderr or history_result.stdout) or "assistant response not found")
      end)
    end)
  end)
end

function M.stop()
  if job_running(state.job_id) then
    vim.fn.jobstop(state.job_id)
  end
  state.root = nil
  state.port = nil
  state.job_id = nil
  state.session_id = nil
  state.started = false
end

function M.new_session(cb)
  M.stop()
  M.ensure_started(nil, cb or function() end)
end

return M
