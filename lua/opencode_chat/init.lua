local config = require("opencode_chat.config")
local server = require("opencode_chat.server")
local ui = require("opencode_chat.ui")
local picker = require("opencode_chat.picker")
local context = require("opencode_chat.context")
local commands = require("opencode_chat.commands")

local M = {}
local request = {
  busy = false,
  cancelling = false,
  id = 0,
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

local function set_configured_keymaps(keymaps)
  if type(keymaps) ~= "table" then
    return
  end
  local opts = { noremap = true, silent = true }
  local maps = {
    toggle = { mode = { "n", "i" }, rhs = function() require("opencode_chat").toggle_from_keymap() end, desc = "Toggle opencode chat" },
    append_context = { mode = { "n", "v" }, rhs = function() require("opencode_chat").append_context() end, desc = "Append context to opencode chat" },
    append_selection = { mode = "v", rhs = function() require("opencode_chat").append_selection() end, desc = "Append selection to opencode chat" },
    sessions = { mode = "n", rhs = function() require("opencode_chat").show_sessions() end, desc = "List opencode sessions" },
    new_session = { mode = "n", rhs = function() require("opencode_chat").new_session() end, desc = "New opencode session" },
    rename_session = { mode = "n", rhs = function() require("opencode_chat").rename_session() end, desc = "Rename opencode session" },
    models = { mode = "n", rhs = function() require("opencode_chat").show_models() end, desc = "Select opencode model" },
    variants = { mode = "n", rhs = function() require("opencode_chat").show_variants() end, desc = "Select opencode variant" },
  }
  for name, lhs in pairs(keymaps) do
    local map = maps[name]
    if map and lhs and lhs ~= "" then
      vim.keymap.set(map.mode, lhs, map.rhs, vim.tbl_extend("force", opts, { desc = map.desc }))
    end
  end
end

local function setup_autoclose()
  local group = vim.api.nvim_create_augroup("opencode_chat_autoclose", { clear = true })
  vim.api.nvim_create_autocmd({ "WinClosed", "TabEnter" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        pcall(ui.close_if_only_chat_windows)
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "TabEnter", "TabNewEntered" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        pcall(ui.show_current_tab_if_visible)
      end)
    end,
  })
end

function M.setup(opts)
  local cfg = config.setup(opts)
  commands.setup(M)
  set_configured_keymaps(cfg.keymaps)
  setup_autoclose()
  return M
end

function M.toggle()
  return ui.toggle()
end

function M.toggle_from_keymap()
  local mode = vim.api.nvim_get_mode().mode
  if mode == "i" or mode == "ic" or mode == "ix" then
    pcall(vim.cmd, "stopinsert")
    vim.schedule(function()
      require("opencode_chat").toggle()
    end)
    return ui.state()
  end
  return M.toggle()
end

function M.show()
  return ui.show()
end

function M.submit()
  if request.busy then
    notify_error("opencode is still responding; use <C-c> or :OpencodeCancel first")
    return
  end
  local text = ui.input_text()
  if text == "" then
    notify_error("opencode prompt is empty")
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
    notify_error("opencode is still responding; use <C-c> or :OpencodeCancel first")
    return
  end

  local prompt, project_root = build_prompt(text)
  request.busy = true
  request.id = request.id + 1
  local request_id = request.id
  ui.add_message("User", prompt)
  ui.add_message("Assistant", "Thinking...")
  start_spinner("Thinking")
  local streamed = false

  server.send(prompt, project_root, function(ok, reply, err)
    vim.schedule(function()
      if request_id ~= request.id then
        return
      end
      request.busy = false
      stop_spinner(ok and "Idle" or "Error")
      if ok then
        if streamed then
          ui.update_last("Assistant", reply ~= "" and reply or "(empty response)")
        else
          ui.replace_last_if("Assistant", "Thinking...", "Assistant", reply ~= "" and reply or "(empty response)")
        end
      else
        ui.replace_last_if("Assistant", "Thinking...", "Error", tostring(err or "opencode request failed"))
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
end

function M.cancel()
  if not request.busy then
    notify_error("no active opencode request")
    return
  end
  if request.cancelling then
    notify_error("opencode request is already cancelling")
    return
  end
  request.id = request.id + 1
  request.cancelling = true
  ui.mark_cancelling()
  stop_spinner("Cancelling")
  server.cancel(function(ok, message)
    vim.schedule(function()
      request.busy = false
      request.cancelling = false
      ui.set_status(ok and "Cancelled" or "Error")
      if ok then
        ui.replace_last_if("System", "Cancelling...", "Cancelled", "Cancelled by opencode.")
      else
        ui.replace_last_if("System", "Cancelling...", "Error", tostring(message or "cancel failed"))
      end
    end)
  end)
end

function M.append_file()
  local item, project_root = context.file_item(0)
  ui.add_context(item, project_root)
end

function M.append_selection()
  local item, project_root = context.selection_item(0)
  ui.add_context(item, project_root)
end

function M.append_context()
  local mode = vim.api.nvim_get_mode().mode
  local is_visual = mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" or mode == "\19"
  local item, project_root
  if is_visual then
    item, project_root = context.selection_item(0)
  else
    item, project_root = context.file_item(0)
  end
  ui.add_context(item, project_root, { focus = "none", leave_visual = is_visual })
end

function M.remove_context(index)
  if not ui.remove_context(index) then
    notify_error("opencode context item not found: " .. tostring(index))
    return false
  end
  return true
end

function M.remove_context_at_cursor()
  local index = ui.context_index_at_cursor()
  if not index then
    notify_error("move cursor to a context line to remove it")
    return false
  end
  return M.remove_context(index)
end

function M.clear_context()
  ui.clear_context()
end

function M.edit(instruction)
  if request.busy then
    notify_error("opencode is still responding; use <C-c> or :OpencodeCancel first")
    return
  end
  instruction = instruction ~= "" and instruction or "Modify the current file as requested."
  local item, project_root = context.file_item(0)
  local prompt = table.concat({
    "You are editing a file in the current project.",
    "Use the configured opencode agent to make the change directly when appropriate.",
    "After editing, summarize what changed.",
    "File: " .. item.relative,
    "Instruction: " .. instruction,
    "Current content:",
    "```" .. (item.ft or ""),
    item.text,
    "```",
  }, "\n")

  ui.add_message("User", "/edit " .. instruction)
  ui.add_message("Assistant", "Editing...")
  request.busy = true
  request.id = request.id + 1
  local request_id = request.id
  start_spinner("Editing")
  server.send(prompt, project_root, function(ok, reply, err)
    vim.schedule(function()
      if request_id ~= request.id then
        return
      end
      request.busy = false
      stop_spinner(ok and "Idle" or "Error")
      if not ok then
        ui.replace_last_if("Assistant", "Editing...", "Error", tostring(err or "opencode edit failed"))
        return
      end
      ui.update_last("Assistant", reply ~= "" and reply or "(edit completed)")
    end)
  end, {
    on_delta = function(text)
      vim.schedule(function()
        if request_id == request.id then
          stop_spinner("Streaming")
          ui.update_last("Assistant", text)
          ui.set_status("Streaming")
        end
      end)
    end,
  })
end

function M.new_session()
  if request.busy then
    notify_error("opencode is still responding; use <C-c> or :OpencodeCancel first")
    return
  end
  ui.clear()
  server.new_session(function(ok, _state, err)
    if not ok then
      notify_error("opencode new session failed: " .. tostring(err))
    end
  end)
end

function M.show_sessions()
  server.list_sessions(function(ok, sessions, err)
    vim.schedule(function()
      if not ok then
        notify_error("opencode list sessions failed: " .. tostring(err))
        return
      end
      local current = server.state().session_id
      local items = {}
      for _, session in ipairs(sessions or {}) do
        local label = session.id
        if session.title and session.title ~= session.id then
          label = session.title .. " (" .. session.id .. ")"
        end
        table.insert(items, {
          label = label,
          selected = session.id == current,
          value = session.id,
          session = session,
        })
      end
      picker.show({
        title = "opencode sessions (<CR> select, r rename, d delete)",
        items = items,
        on_select = function(item)
          M.select_session(item.value)
        end,
        actions = {
          r = function(item)
            M.rename_session(nil, item.value)
          end,
          d = function(item)
            M.delete_session(item.value, item.label)
          end,
        },
      })
    end)
  end)
end

function M.select_session(session_id)
  if request.busy then
    notify_error("opencode is still responding; use <C-c> or :OpencodeCancel first")
    return
  end
  server.select_session(session_id, function(ok, history, err)
    vim.schedule(function()
      if not ok then
        notify_error("opencode select session failed: " .. tostring(err))
        return
      end
      local messages = require("opencode_chat.client").to_chat_messages(history)
      if #messages == 0 then
        messages = { { role = "System", text = "Session selected: " .. tostring(session_id) } }
      end
      ui.set_messages(messages)
    end)
  end)
end

function M.rename_session(title, session_id)
  if request.busy then
    notify_error("opencode is still responding; use <C-c> or :OpencodeCancel first")
    return
  end
  local current = session_id or server.state().session_id
  if not current then
    notify_error("no active opencode session")
    return
  end
  local function apply(new_title)
    new_title = vim.trim(new_title or "")
    if new_title == "" then
      return
    end
    server.rename_session(current, new_title, function(ok, _data, err)
      vim.schedule(function()
        if not ok then
          notify_error("opencode rename session failed: " .. tostring(err))
          return
        end
        ui.add_message("System", "Session renamed: " .. new_title)
        if picker.state().buf then
          M.show_sessions()
        end
      end)
    end)
  end
  if title and title ~= "" then
    apply(title)
    return
  end
  local session = server.state().sessions[current] or {}
  vim.ui.input({ prompt = "Session title: ", default = session.title or "" }, apply)
end

function M.delete_session(session_id, label)
  if request.busy then
    notify_error("opencode is still responding; use <C-c> or :OpencodeCancel first")
    return
  end
  if not session_id or session_id == "" then
    notify_error("session id is required")
    return
  end
  vim.ui.input({ prompt = "Delete session " .. tostring(label or session_id) .. "? Type y to confirm: " }, function(answer)
    if vim.trim(answer or "") ~= "y" then
      return
    end
    server.delete_session(session_id, function(ok, _data, err)
      vim.schedule(function()
        if not ok then
          notify_error("opencode delete session failed: " .. tostring(err))
          return
        end
        ui.add_message("System", "Session deleted: " .. tostring(label or session_id))
        if picker.state().buf then
          M.show_sessions()
        end
      end)
    end)
  end)
end

function M.show_models()
  local current = config.current_model()
  local items = {}
  for _, model in ipairs(config.models()) do
    table.insert(items, {
      group = model.providerID,
      label = model.modelID,
      selected = model.providerID == current.providerID and model.modelID == current.modelID,
      value = model,
    })
  end
  picker.show({
    title = "opencode models",
    items = items,
    on_select = function(item)
      M.select_model(item.value.providerID, item.value.modelID)
    end,
  })
end

function M.select_model(provider_id, model_id)
  local ok, result = config.select_model(provider_id, model_id)
  if not ok then
    notify_error(result)
    return false
  end
  ui.add_message("System", "Model selected: " .. result.providerID .. "/" .. result.modelID .. " (variant: " .. result.variant .. ")")
  return true
end

function M.show_variants()
  local current = config.current_model()
  local items = {}
  for _, variant in ipairs(config.variants(current.providerID)) do
    table.insert(items, {
      label = variant,
      selected = variant == current.variant,
      value = variant,
    })
  end
  picker.show({
    title = current.providerID .. " variants",
    items = items,
    on_select = function(item)
      M.select_variant(item.value)
    end,
  })
end

function M.select_variant(variant)
  local ok, result = config.select_variant(variant)
  if not ok then
    notify_error(result)
    return false
  end
  ui.add_message("System", "Variant selected: " .. result.variant)
  return true
end

function M.stop()
  request.busy = false
  request.cancelling = false
  request.id = request.id + 1
  stop_spinner("Idle")
  server.stop()
  ui.close()
end

M._build_prompt = build_prompt
M._request = request

return M
