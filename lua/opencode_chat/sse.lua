local debug = require("opencode_chat.debug")

local M = {}

--- SSE 帧格式兼容双来源：
---   1. 真实 opencode: { type="message.part.delta", properties={ sessionID, delta } }
---   2. test fixture:   { type="message.part.delta", properties={ sessionID, part={ text } } }
local function extract_delta_text(properties)
  if type(properties) ~= "table" then
    return ""
  end

  -- opencode stable v1: { delta }
  if type(properties.delta) == "string" and properties.delta ~= "" then
    return properties.delta
  end

  -- test fixture: { part: { text } }
  local part = properties.part
  if type(part) == "table" and type(part.text) == "string" and part.text ~= "" then
    return part.text
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

--- 检查事件是否为完成信号
local function is_completion_event(event, session_id)
  if not match_session(event, session_id) then
    return false
  end
  local typ = event.type
  if typ == "session.idle" then
    return true
  end
  if typ == "session.status" then
    local status = event.properties
    if type(status) == "table" and status.status then
      status = status.status
    end
    if type(status) == "table" and status.type == "idle" then
      return true
    end
  end
  if typ == "message.updated" then
    local info = event.properties
    if type(info) == "table" and info.info then
      info = info.info
    end
    local t = type(info) == "table" and info.time
    if type(t) == "table" and t.completed ~= nil then
      return true
    end
  end
  return false
end

--- 从 buffer 中提取完整的 SSE 帧。
--- 返回: { frames = {frame1, ...}, consumed = 已消费字节数 }
--- frame 结构: { data = "json_str" }  — 提取自 "data: <json>" 行
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

    -- 提取 data: 行（忽略 event: / id: 等行）
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
--- @param callbacks  { on_delta(text_chunk), on_completed(), on_error(err_msg) }
--- @return handle  { cancel() }
function M.subscribe(opts, callbacks)
  local uv = vim.uv or vim.loop
  local tcp = assert(uv.new_tcp(), "failed to create tcp socket")
  local buffer = ""
  local cancelled = false
  local backoff_seconds = 1
  local max_retries = 3
  local retry_count = 0
  local heartbeat_timer  -- 心跳 watchdog

  -- 前向声明
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
      callbacks.on_error(err_msg)
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

  --- 处理一条 JSON 事件
  local function process_event(json_str)
    local ok, event = pcall(vim.json.decode, json_str)
    if not ok or type(event) ~= "table" then
      return
    end

    local typ = event.type

    -- 心跳/connected：重置 watchdog
    if typ == "server.heartbeat" or typ == "server.connected" then
      reset_heartbeat()
      return
    end

    -- 检查是否属于目标 session
    if not match_session(event, opts.session_id) then
      return
    end

    -- 完成信号？
    if is_completion_event(event, opts.session_id) then
      debug.log("sse", "completed", {
        session_id = opts.session_id,
        event_type = typ,
      })
      complete()
      return
    end

    -- 增量文本
    if typ == "message.part.delta" then
      local text = extract_delta_text(event.properties)
      if text ~= "" then
        emit_delta(text)
      end
      return
    end
  end

  --- 处理收到的原始字节流
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
      -- EOF — 服务器关闭了连接
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

  --- 重置心跳计时器
  function reset_heartbeat()
    if heartbeat_timer then
      heartbeat_timer:start(30000, 0, function()
        debug.log("sse", "heartbeat_timeout", { session_id = opts.session_id })
        close()
        retry()
      end)
    end
  end

  --- 重连（指数退避）
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

  --- 建立 TCP 连接并发送 HTTP 请求
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

    -- 创建新 socket（旧 socket 已在 retry/close 时关闭）
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

      -- 启动心跳 watchdog
      if heartbeat_timer then
        heartbeat_timer:stop()
        heartbeat_timer:close()
      end
      heartbeat_timer = uv.new_timer()
      reset_heartbeat()

      -- 开始读取
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
