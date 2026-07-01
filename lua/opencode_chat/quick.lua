local server = require("opencode_chat.server")
local ui = require("opencode_chat.quick_ui")
local context = require("opencode_chat.context")

local M = {}

local request = {
  busy = false,
  cancelling = false,
  closing = false,
  id = 0,
  session = nil,
  handle = nil,
}

local spinner = {
  timer = nil,
  index = 1,
  frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
}

local function notify_error(message)
  vim.schedule(function()
    vim.notify(message, vim.log.levels.ERROR)
  end)
end

local function stop_spinner(status)
  if spinner.timer then
    spinner.timer:stop()
    spinner.timer:close()
    spinner.timer = nil
  end
  ui.set_status(status or "Idle")
end

local function start_spinner(label)
  stop_spinner(label)
  spinner.index = 1
  spinner.timer = vim.loop.new_timer()
  spinner.timer:start(0, 120, vim.schedule_wrap(function()
    if not request.busy then
      stop_spinner("Idle")
      return
    end
    local frame = spinner.frames[spinner.index]
    spinner.index = (spinner.index % #spinner.frames) + 1
    ui.set_status((label or "Thinking") .. " " .. frame)
  end))
end

local function build_prompt(text)
  local items, project_root = ui.consume_context()
  local context_text = ui.context_prompt(items)
  if context_text == "" then
    return text, project_root
  end
  return context_text .. "\n\n" .. text, project_root
end

local function usable_context_buf()
  local function usable(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
      return false
    end
    local name = vim.api.nvim_buf_get_name(buf)
    return type(name) == "string" and name ~= "" and not name:match("^opencode%-chat://") and vim.loop.fs_stat(name) ~= nil
  end
  if usable(0) then
    return 0
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if usable(buf) then
      return buf
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if usable(buf) then
      return buf
    end
  end
  return 0
end

local function delete_session(session, cb)
  if not session then
    if cb then
      cb(true)
    end
    return
  end
  local sync_ok = server.delete_ephemeral_sync(session)
  if sync_ok then
    if cb then
      cb(true)
    end
    return
  end
  server.delete_ephemeral(session, function(ok, _data, err)
    if not ok then
      notify_error("opencode quick session cleanup failed: " .. tostring(err))
    end
    if cb then
      cb(ok)
    end
  end)
end

local function clear_request_session()
  request.session = nil
  request.handle = nil
end

local function cleanup_session(opts, cb)
  opts = opts or {}
  local session = request.session
  request.session = nil
  if (opts.abort or request.busy) and request.handle and request.handle.cancel then
    request.handle.cancel()
  end
  request.handle = nil

  local function after_abort()
    delete_session(session, function(ok)
      if cb then
        cb(ok)
      end
    end)
  end

  if opts.abort and session then
    server.abort_ephemeral(session, function()
      vim.schedule(after_abort)
    end)
    return
  end
  after_abort()
end

local function send_with_session(prompt, project_root, request_id)
  local streamed = false
  request.handle = server.send_ephemeral(request.session, prompt, function(ok, reply, err)
    vim.schedule(function()
      if request_id ~= request.id then
        return
      end
      request.busy = false
      request.handle = nil
      stop_spinner(ok and "Idle" or "Error")
      if ok then
        if streamed then
          ui.update_last("Assistant", reply ~= "" and reply or "(empty response)")
        else
          ui.replace_last_if("Assistant", "Thinking...", "Assistant", reply ~= "" and reply or "(empty response)")
        end
      else
        ui.replace_last_if("Assistant", "Thinking...", "Error", tostring(err or "opencode quick request failed"))
      end
    end)
  end, {
    on_delta = function(text)
      streamed = true
      vim.schedule(function()
        if request_id == request.id then
          stop_spinner("Streaming")
          ui.update_last("Assistant", text)
          ui.set_status("Streaming")
        end
      end)
    end,
  })

  if not request.handle and not request.session then
    request.busy = false
    stop_spinner("Error")
    ui.replace_last_if("Assistant", "Thinking...", "Error", "quick session is missing")
  end
  return project_root
end

function M.show(text)
  ui.show()
  if text and text ~= "" then
    M.ask(text)
  end
end

function M.submit()
  if request.busy then
    notify_error("opencode quick ask is still responding; use <C-c> first")
    return
  end
  local text = ui.input_text()
  if text == "" then
    notify_error("opencode quick prompt is empty")
    return
  end
  ui.clear_input()
  M.ask(text)
end

function M.ask(text)
  if not text or text == "" then
    ui.show()
    return
  end
  if request.busy then
    notify_error("opencode quick ask is still responding; use <C-c> first")
    return
  end

  local prompt, project_root = build_prompt(text)
  request.busy = true
  request.cancelling = false
  request.id = request.id + 1
  local request_id = request.id
  ui.add_message("User", prompt)
  ui.add_message("Assistant", "Thinking...")
  start_spinner("Thinking")

  if request.session then
    send_with_session(prompt, project_root, request_id)
    return
  end

  server.create_ephemeral_session(project_root, function(ok, session, err)
    vim.schedule(function()
      if request_id ~= request.id then
        if ok and session then
          delete_session(session)
        end
        return
      end
      if not ok then
        request.busy = false
        stop_spinner("Error")
        ui.replace_last_if("Assistant", "Thinking...", "Error", tostring(err or "failed to create quick session"))
        return
      end
      request.session = session
      send_with_session(prompt, project_root, request_id)
    end)
  end)
end

function M.cancel()
  if not request.busy then
    notify_error("no active opencode quick request")
    return
  end
  if request.cancelling then
    notify_error("opencode quick request is already cancelling")
    return
  end
  request.id = request.id + 1
  request.cancelling = true
  ui.mark_cancelling()
  stop_spinner("Cancelling")
  cleanup_session({ abort = true }, function()
    vim.schedule(function()
      request.busy = false
      request.cancelling = false
      ui.set_status("Cancelled")
      ui.replace_last_if("System", "Cancelling...", "Cancelled", "Quick ask cancelled and session deleted.")
    end)
  end)
end

function M.close()
  request.id = request.id + 1
  local was_busy = request.busy
  request.busy = false
  request.cancelling = false
  stop_spinner("Idle")
  cleanup_session({ abort = was_busy }, function()
    clear_request_session()
  end)
  ui.close()
end

function M.append_file()
  local item, project_root = context.file_item(usable_context_buf())
  ui.add_context(item, project_root)
end

function M.append_selection()
  local item, project_root = context.selection_item(0)
  ui.add_context(item, project_root)
end

function M.append_context()
  local mode = vim.api.nvim_get_mode().mode
  local is_visual = mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" or mode == "\19"
  if is_visual then
    M.append_selection()
  else
    M.append_file()
  end
end

function M.remove_context(index)
  if not ui.remove_context(index) then
    notify_error("opencode quick context item not found: " .. tostring(index))
    return false
  end
  return true
end

function M.remove_context_at_cursor()
  local index = ui.context_index_at_cursor()
  if not index then
    notify_error("move cursor to a quick context line to remove it")
    return false
  end
  return M.remove_context(index)
end

function M.clear_context()
  ui.clear_context()
end

function M.state()
  return request
end

return M
