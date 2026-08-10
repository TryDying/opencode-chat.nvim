local client = require("opencode_chat.client")
local sse = require("opencode_chat.sse")
local debug = require("opencode_chat.debug")

local M = {}

--- 发起一次流式请求。
--- 顺序：SSE 先订阅 → on_connected → prompt_async → stream → complete/error/cancel
---
--- @param opts {
---   session_id: string,
---   host: string,
---   port: number,
---   directory: string,
---   text: string,           -- 完整 prompt 文本
---   model: table,           -- { providerID, modelID }
---   agent: string,
---   variant: string,
---   timeout_ms: number?,
--- }
--- @param callbacks {
---   on_delta: fun(text_chunk: string)?,     -- 流式增量文本（可选）
---   on_reasoning: fun(text_chunk: string)?, -- 推理/思考内容（可选，不混入主回复）
---   on_spinner: fun(frame_text: string)?,   -- spinner 帧文字（可选）
---   on_completed: fun(full_text: string),   -- 请求成功完成，附带完整回复文本
---   on_error: fun(err_msg: string),          -- 请求失败（含取消）
---   on_cancelled: fun()?,                    -- 用户取消（可选，未提供则走 on_error("Cancelled")）
--- }
--- @return handle { cancel: fun(), is_busy: fun():boolean }
function M.send(opts, callbacks)
  callbacks = callbacks or {}

  local cancelled = false
  local done = false
  local sse_handle
  local spinner_timer
  local accumulated = {}
  local reasoning_accumulated = {}

  local function finish()
    if done then
      return
    end
    done = true
    if spinner_timer then
      spinner_timer:stop()
      spinner_timer:close()
      spinner_timer = nil
    end
    if sse_handle then
      sse_handle.cancel()
      sse_handle = nil
    end
  end

  -- 启动 spinner timer（可选）
  if callbacks.on_spinner then
    local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
    local index = 1
    spinner_timer = vim.uv.new_timer()
    spinner_timer:start(0, 120, vim.schedule_wrap(function()
      if done then
        return
      end
      callbacks.on_spinner(frames[index])
      index = (index % #frames) + 1
    end))
  end

  local function on_completed_internal()
    if cancelled then
      return
    end
    local full_text = table.concat(accumulated, "")
    finish()
    vim.schedule(function()
      callbacks.on_completed(full_text)
    end)
  end

  local function on_error_internal(err_msg)
    if cancelled then
      return
    end
    finish()
    vim.schedule(function()
      callbacks.on_error(err_msg)
    end)
  end

  -- Step 1: 先订阅 SSE
  sse_handle = sse.subscribe({
    host = opts.host,
    port = opts.port,
    directory = opts.directory,
    session_id = opts.session_id,
  }, {
    on_connected = function()
      -- Step 2: SSE 连接就绪后发送 prompt_async
      if cancelled then
        return
      end
      debug.log("chat", "sse_connected", { session_id = opts.session_id })

      client.send_message_async(opts.session_id, opts.text, {
        host = opts.host,
        port = opts.port,
        model = opts.model,
        agent = opts.agent,
        variant = opts.variant,
        timeout_ms = opts.timeout_ms,
      }, function(sent, _data, result)
        if cancelled then
          return
        end
        if not sent then
          -- prompt_async 发送失败
          on_error_internal(client.format_error(result, "failed to send prompt"))
        end
        -- 成功：SSE 将交付后续事件
      end)
    end,
    on_delta = function(text_chunk)
      if cancelled or done then
        return
      end
      table.insert(accumulated, text_chunk)
      if callbacks.on_delta then
        callbacks.on_delta(text_chunk)
      end
    end,
    on_reasoning = function(text_chunk)
      -- 累积 reasoning 但不混入主回复文本
      if cancelled or done then
        return
      end
      table.insert(reasoning_accumulated, text_chunk)
      if callbacks.on_reasoning then
        callbacks.on_reasoning(text_chunk)
      end
    end,
    on_completed = function()
      on_completed_internal()
    end,
    on_error = function(err_msg)
      on_error_internal(err_msg)
    end,
  })

  return {
    cancel = function()
      if cancelled or done then
        return
      end
      cancelled = true
      finish()
      -- Abort first, then notify caller
      client.abort_session(opts.session_id, {
        host = opts.host,
        port = opts.port,
      }, function()
        vim.schedule(function()
          if callbacks.on_cancelled then
            callbacks.on_cancelled()
          else
            callbacks.on_error("Cancelled")
          end
        end)
      end)
    end,
    is_busy = function()
      return not done
    end,
  }
end

return M
