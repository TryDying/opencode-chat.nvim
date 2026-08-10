local debug = require("opencode_chat.debug")

local M = {}

--- 从当前 OpenCode API 格式提取 delta 文本：properties.delta
local function extract_delta_text(properties)
  if type(properties) ~= "table" then
    return ""
  end
  if type(properties.delta) == "string" and properties.delta ~= "" then
    return properties.delta
  end
  return ""
end

--- 检查事件是否属于目标 session
local function match_session(event, session_id)
  if type(event) ~= "table" then
    return false
  end
  local props = event.properties
  if type(props) ~= "table" then
    return false
  end
  return props.sessionID == session_id
end

--- 检查事件是否为完成信号。
--- session.status {type:"idle"} 优先，session.idle (deprecated) 作为 fallback。
local function is_completion_event(event, session_id)
  if not match_session(event, session_id) then
    return false
  end
  local typ = event.type
  if typ == "session.status" then
    local props = event.properties or {}
    local status = props.status
    if type(status) == "table" and status.type == "idle" then
      return true
    end
  end
  if typ == "session.idle" then
    return true
  end
  return false
end

--- 从 buffer 中提取完整的 SSE 帧。
--- 返回: { frames = {frame1, ...}, consumed = 已消费字节数 }
local function extract_frames(buffer)
  local frames = {}
  local pos = 1
  local consumed = 0

  while pos <= #buffer do
    local start_pos, end_pos = buffer:find("\n\n", pos, true)
    if not start_pos then
      break
    end
    consumed = end_pos
    local frame_text = buffer:sub(pos, start_pos - 1)
    pos = end_pos + 1

    for line in frame_text:gmatch("[^\r\n]+") do
      local data_match = line:match("^data:%s?(.+)$")
      if data_match then
        table.insert(frames, { data = data_match })
        break
      end
    end
  end

  return { frames = frames, consumed = consumed }
end

--- 启动 SSE 订阅
--- @param opts  { host, port, directory, session_id }
--- @param callbacks  {
---   on_connected = function(),       -- SSE 连接就绪（收到 server.connected）
---   on_delta = function(text_chunk), -- message.part.delta / session.next.text.delta
---   on_reasoning = function(text),   -- session.next.reasoning.delta (可选)
---   on_tool = function(typ, props),  -- session.next.tool.* (可选)
---   on_error = function(err_msg),    -- SSE session.error 或连接错误 (可选)
---   on_event = function(typ, props), -- 透传所有未分类事件 (可选)
---   on_completed = function(),       -- 请求完成
--- }
--- @return handle  { cancel() }
function M.subscribe(opts, callbacks)
  local uv = vim.uv or vim.loop
  local tcp = assert(uv.new_tcp(), "failed to create tcp socket")
  local buffer = ""
  local cancelled = false
  local connected = false
  local backoff_seconds = 1
  local max_retries = 3
  local retry_count = 0
  local heartbeat_timer

  local reset_heartbeat
  local retry
  local connect

  local function close()
    if not tcp:is_closing() then
      tcp:close()
    end
    if heartbeat_timer then
      heartbeat_timer:stop()
      heartbeat_timer:close()
      heartbeat_timer = nil
    end
  end

  local function fail(err_msg)
    if cancelled then
      return
    end
    cancelled = true
    close()
    vim.schedule(function()
      if callbacks.on_error then
        callbacks.on_error(err_msg)
      else
        callbacks.on_completed()
      end
    end)
  end

  local function complete()
    if cancelled then
      return
    end
    cancelled = true
    close()
    vim.schedule(function()
      callbacks.on_completed()
    end)
  end

  local function emit_delta(text)
    if cancelled or text == "" then
      return
    end
    vim.schedule(function()
      if cancelled then
        return
      end
      callbacks.on_delta(text)
    end)
  end

  --- 处理一条 JSON 事件：路由到对应回调
  local function process_event(json_str)
    local ok, event = pcall(vim.json.decode, json_str)
    if not ok or type(event) ~= "table" then
      return
    end

    local typ = event.type
    local props = event.properties or {}

    -- 连接管理
    if typ == "server.connected" then
      if not connected then
        connected = true
        vim.schedule(function()
          if callbacks.on_connected then
            callbacks.on_connected()
          end
        end)
      end
      reset_heartbeat()
      return
    end

    if typ == "server.heartbeat" then
      reset_heartbeat()
      return
    end

    -- 检查是否属于目标 session（完成信号和 session-level 事件需要 session 匹配）
    if not match_session(event, opts.session_id) then
      return
    end

    -- 完成信号
    if is_completion_event(event, opts.session_id) then
      debug.log("sse", "completed", {
        session_id = opts.session_id,
        event_type = typ,
      })
      complete()
      return
    end

    -- 增量文本：v1 compat message.part.delta
    if typ == "message.part.delta" then
      local text = extract_delta_text(props)
      if text ~= "" then
        emit_delta(text)
      end
      return
    end

    -- 增量文本：新引擎 session.next.text.delta
    if typ == "session.next.text.delta" then
      local text = extract_delta_text(props)
      if text ~= "" then
        emit_delta(text)
      end
      return
    end

    -- 推理 delta
    if typ == "session.next.reasoning.delta" then
      local text = extract_delta_text(props)
      if text ~= "" and callbacks.on_reasoning then
        vim.schedule(function()
          callbacks.on_reasoning(text)
        end)
      end
      return
    end

    -- 工具事件
    if typ:match("^session%.next%.tool%.") then
      if callbacks.on_tool then
        vim.schedule(function()
          callbacks.on_tool(typ, props)
        end)
      end
      return
    end

    -- Session 级错误
    if typ == "session.error" then
      if callbacks.on_error then
        local err = props.error or {}
        local msg = err.message or err.name or vim.inspect(err)
        vim.schedule(function()
          callbacks.on_error(msg)
        end)
      end
      return
    end

    -- 透传其余事件
    if callbacks.on_event then
      vim.schedule(function()
        callbacks.on_event(typ, props)
      end)
    end
  end

  local function on_data(read_err, chunk)
    if cancelled then
      return
    end
    if read_err then
      debug.log("sse", "read_error", { session_id = opts.session_id, error = read_err })
      retry()
      return
    end
    if not chunk then
      debug.log("sse", "eof", { session_id = opts.session_id })
      retry()
      return
    end

    buffer = buffer .. chunk
    local result = extract_frames(buffer)
    if result.consumed > 0 then
      buffer = buffer:sub(result.consumed + 1)
    end

    for _, frame in ipairs(result.frames) do
      if frame.data and frame.data ~= "" then
        process_event(frame.data)
      end
    end
  end

  function reset_heartbeat()
    if heartbeat_timer then
      heartbeat_timer:start(30000, 0, function()
        debug.log("sse", "heartbeat_timeout", { session_id = opts.session_id })
        close()
        retry()
      end)
    end
  end

  function retry()
    if cancelled then
      return
    end
    retry_count = retry_count + 1
    if retry_count > max_retries then
      debug.log("sse", "retry_exhausted", {
        session_id = opts.session_id,
        retry_count = retry_count,
      })
      fail("SSE connection lost after " .. max_retries .. " retries")
      return
    end

    local delay = backoff_seconds * 1000
    backoff_seconds = backoff_seconds * 2
    debug.log("sse", "retry", {
      session_id = opts.session_id,
      attempt = retry_count,
      delay_ms = delay,
    })
    vim.defer_fn(function()
      if cancelled then
        return
      end
      connect()
    end, delay)
  end

  function connect()
    if cancelled then
      return
    end

    local directory = opts.directory or ""
    local query_value = tostring(directory):gsub("([^%w%-%._~])", function(char)
      return string.format("%%%02X", string.byte(char))
    end)

    debug.log("sse", "connect", {
      session_id = opts.session_id,
      host = opts.host,
      port = opts.port,
      directory = directory,
    })

    if tcp:is_closing() then
      tcp = assert(uv.new_tcp(), "failed to create tcp socket")
    end

    tcp:connect(opts.host, opts.port, function(err)
      if cancelled then
        return
      end
      if err then
        debug.log("sse", "connect_error", { session_id = opts.session_id, error = err })
        retry()
        return
      end

      local request = string.format(
        "GET /event?directory=%s HTTP/1.1\r\n"
          .. "Host: %s:%s\r\n"
          .. "Accept: text/event-stream\r\n"
          .. "Cache-Control: no-cache\r\n"
          .. "\r\n",
        query_value,
        opts.host,
        opts.port
      )
      tcp:write(request)

      if heartbeat_timer then
        heartbeat_timer:stop()
        heartbeat_timer:close()
      end
      heartbeat_timer = uv.new_timer()
      reset_heartbeat()

      tcp:read_start(function(read_err, chunk)
        on_data(read_err, chunk)
      end)
    end)
  end

  connect()

  return {
    cancel = function()
      if cancelled then
        return
      end
      cancelled = true
      close()
    end,
  }
end

return M
