local client = require("opencode_chat.client")
local sse = require("opencode_chat.sse")
local M = {}

-- One admission per request. SSE reconnection never resubmits the prompt.
function M.send(opts, callbacks)
  callbacks = callbacks or {}
  local stream, spinner, deadline
  local done, cancelling, submitted, admitted, started = false, false, false, false, false
  local inbox_id
  local blocks, order = {}, {}
  local cancel_waiters = {}
  local timeout_error
  local cancelling_backend, completion_pending, waiting = false, false, nil
  local cancel_backend

  local function text()
    local out = {}
    for _, id in ipairs(order) do table.insert(out, blocks[id]) end
    return table.concat(out, "")
  end
  local function finish(kind, value)
    if done then return end
    done = true
    if stream then stream.cancel() end
    if spinner then spinner:stop(); spinner:close() end
    if deadline then deadline:stop(); deadline:close() end
    vim.schedule(function()
      if callbacks[kind] then callbacks[kind](value) end
      for _, cb in ipairs(cancel_waiters) do cb(kind == "on_cancelled") end
      cancel_waiters = {}
    end)
  end
  local function fail(message) finish("on_error", message) end
  local function reconcile(final)
    if done or cancelling or not admitted then return end
    client.get_messages(opts.session_id, opts, function(ok, messages, result)
      if done or cancelling then return end
      if not ok then fail(client.format_error(result, "failed to recover message history")); return end
      local found, out = false, {}
      for _, message in ipairs(messages) do
        if message.id == inbox_id then found = true end
        if found and message.type == "assistant" then
          local _, value = client.extract_message_role_text(message)
          table.insert(out, value)
        end
      end
      local last = messages[#messages]
      if final or (found and last and last.type == "idle") then
        finish("on_completed", #out > 0 and table.concat(out, "") or text())
      end
    end)
  end
  cancel_backend = function()
    if done or cancelling_backend then return end
    cancelling_backend = true
    local function notify(ok, result)
      if timeout_error then
        fail(timeout_error .. (ok and " (backend interrupted)" or ("; " .. client.format_error(result, "backend cancellation failed"))))
      else
        finish(ok and "on_cancelled" or "on_error", ok and nil or client.format_error(result, "backend cancellation failed"))
      end
    end
    local function interrupt()
      client.abort_session(opts.session_id, opts, function(ok, _, result) notify(ok, result) end)
    end
    if inbox_id then
      client.cancel_inbox(opts.session_id, inbox_id, opts, function(ok, _, result)
        if not ok then notify(false, result); return end
        interrupt()
      end)
    else interrupt() end
  end

  if callbacks.on_spinner then
    local frames, index = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }, 0
    spinner = vim.uv.new_timer()
    spinner:start(0, 120, vim.schedule_wrap(function()
      if not done then index = index % #frames + 1; callbacks.on_spinner(waiting or frames[index]) end
    end))
  end
  deadline = vim.uv.new_timer()
  deadline:start(opts.timeout_ms or require("opencode_chat.config").get().response_timeout_ms, 0, vim.schedule_wrap(function()
    if not done then
      timeout_error, cancelling = "OpenCode response timed out", true
      if not submitted or admitted then cancel_backend() end
    end
  end))

  client.configure_session(opts.session_id, opts, function(ok, _, result)
    if done then return end
    if cancelling then cancel_backend(); return end
    if not ok then fail(client.format_error(result, "failed to configure model/agent")); return end
    stream = sse.subscribe(opts, {
      on_connected = function()
        if done or submitted then return end
        if cancelling then cancel_backend(); return end
        submitted = true
        client.send_message_async(opts.session_id, opts.text, opts, function(sent, data, response)
          if done then return end
          if not sent then fail(client.format_error(response, "prompt admission failed")); return end
          admitted, inbox_id = true, data and data.data and data.data.id
          if cancelling then cancel_backend()
          elseif completion_pending then reconcile(true) end
        end)
      end,
      on_reconnected = function() reconcile(false) end,
      on_error = function(message)
        if not cancelling then
          timeout_error, cancelling = message, true
          if not submitted or admitted then cancel_backend() end
        end
      end,
      on_event = function(typ, data)
        if done or cancelling or not submitted then return end
        if typ == "session.execution.started" then started = true end
        if typ == "session.text.delta" or typ == "session.text.ended" then
          local id = tostring(data.assistantMessageID) .. ":" .. tostring(data.ordinal)
          if blocks[id] == nil then blocks[id] = ""; table.insert(order, id) end
          if typ == "session.text.ended" then blocks[id] = data.text or blocks[id]
          else
            blocks[id] = blocks[id] .. (data.delta or "")
            if callbacks.on_delta then callbacks.on_delta(data.delta or "") end
          end
        elseif typ == "session.reasoning.delta" then
          if callbacks.on_reasoning then callbacks.on_reasoning(data.delta or "") end
        elseif typ == "session.execution.failed" then
          fail(type(data.error) == "table" and (data.error.message or vim.inspect(data.error)) or tostring(data.error))
        elseif typ == "session.execution.interrupted" then
          fail("OpenCode execution interrupted: " .. tostring(data.reason))
        elseif typ == "permission.asked" or typ == "form.created" then
          waiting = "Waiting for " .. typ .. " (interaction UI unavailable; cancel with <C-c>)"
          if callbacks.on_spinner then callbacks.on_spinner(waiting) end
        elseif typ == "permission.replied" or typ == "form.replied" or typ == "form.cancelled" then
          waiting = nil
        elseif typ == "session.execution.succeeded" and started then
          completion_pending = true
          reconcile(true)
        elseif typ == "session.status" and data.status and data.status.type == "idle" and started then
          reconcile(true)
        end
      end,
    })
  end)

  return {
    cancel = function(cb)
      if done then if cb then cb(true) end; return end
      if cb then table.insert(cancel_waiters, cb) end
      if cancelling then return end
      cancelling = true
      if not submitted or admitted then cancel_backend() end
      -- If POST is in flight, wait for its inbox id before cancelling it.
    end,
    is_busy = function() return not done end,
  }
end

return M
