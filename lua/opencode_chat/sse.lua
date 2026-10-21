local client = require("opencode_chat.client")
local M = {}

-- curl owns HTTP status/chunk decoding; this module only decodes SSE frames.
function M.subscribe(opts, callbacks)
  local process, timer
  local stopped, ready = false, false
  local attempts, generation = 0, 0
  local connect
  local function emit(name, ...)
    local args = { ... }
    vim.schedule(function()
      if not stopped and callbacks[name] then callbacks[name](unpack(args)) end
    end)
  end
  local function stop()
    stopped = true
    if timer then timer:stop(); timer:close(); timer = nil end
    if process then pcall(process.kill, process, 15); process = nil end
  end
  local function heartbeat()
    if timer then timer:stop(); timer:close() end
    timer = vim.uv.new_timer()
    timer:start(35000, 0, function()
      if process then pcall(process.kill, process, 15) end
    end)
  end
  connect = function()
    if stopped then return end
    generation = generation + 1
    local current = generation
    local buffer, headers, status = "", false, nil
    local args = { "curl", "--config", "-", "-sS", "-N", "-i", "--http1.1", "--connect-timeout", "5", "-H", "Accept: text/event-stream", client.event_url(opts) }
    process = vim.system(args, {
      stdin = client.curl_config(opts),
      stdout = function(err, chunk)
        if stopped or current ~= generation or err or not chunk then return end
        heartbeat()
        buffer = buffer .. chunk
        if not headers then
          local _, last = buffer:find("\r\n\r\n", 1, true)
          if not last then return end
          local header = buffer:sub(1, last)
          status = tonumber(header:match("HTTP/%S+ (%d+)"))
          if status ~= 200 or not header:lower():find("content%-type:%s*text/event%-stream") then
            emit("on_error", "SSE HTTP " .. tostring(status))
            return
          end
          headers = true
          buffer = buffer:sub(last + 1)
          -- The V2 server emits server.connected after feed subscription. Use
          -- that readiness barrier, not just headers (which may precede it).
        end
        buffer = buffer:gsub("\r\n", "\n")
        while true do
          local first, last = buffer:find("\n\n", 1, true)
          if not first then break end
          local frame = buffer:sub(1, first - 1)
          buffer = buffer:sub(last + 1)
          local lines = {}
          for line in frame:gmatch("[^\n]+") do
            local data = line:match("^data:%s?(.*)$")
            if data then table.insert(lines, data) end
          end
          if #lines > 0 then
            local ok, event = pcall(vim.json.decode, table.concat(lines, "\n"))
            if ok and type(event) == "table" then
              if event.type == "server.connected" then
                if ready then emit("on_reconnected") else ready = true; emit("on_connected") end
              elseif type(event.data) == "table" and (event.data.sessionID or (event.data.form and event.data.form.sessionID)) == opts.session_id then
                emit("on_event", event.type, event.data)
              end
            end
          end
        end
      end,
    }, function(result)
      if stopped or current ~= generation then return end
      process = nil
      if timer then timer:stop(); timer:close(); timer = nil end
      if status and status ~= 200 then return end
      attempts = attempts + 1
      if attempts > 3 then
        emit("on_error", "SSE connection lost: " .. (result.stderr or ""))
      else
        vim.defer_fn(connect, 200 * 2 ^ (attempts - 1))
      end
    end)
    heartbeat()
  end
  connect()
  return { cancel = stop }
end

return M
