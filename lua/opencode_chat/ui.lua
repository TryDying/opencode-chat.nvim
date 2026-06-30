local config = require("opencode_chat.config")

local M = {}

local state = {
  message_win = nil,
  status_win = nil,
  input_win = nil,
  tabs = {},
  visible = false,
  message_buf = nil,
  status_buf = nil,
  input_buf = nil,
  messages = {},
  context = {},
  context_root = nil,
  status = "Idle",
  spinner = nil,
  spinner_index = 1,
}

local function valid_win(win_id)
  return win_id and vim.api.nvim_win_is_valid(win_id)
end

local function valid_buf(buf_id)
  return buf_id and vim.api.nvim_buf_is_valid(buf_id)
end

local function is_chat_buf(buf)
  if not valid_buf(buf) then
    return false
  end
  return vim.api.nvim_buf_get_name(buf):match("^opencode%-chat://") ~= nil
end

local function is_chat_win(win)
  if not valid_win(win) then
    return false
  end
  if win == state.message_win or win == state.input_win or win == state.status_win then
    return true
  end
  return is_chat_buf(vim.api.nvim_win_get_buf(win))
end

local function tab_key(tab)
  return tab or vim.api.nvim_get_current_tabpage()
end

local function panes_for(tab)
  return state.tabs[tab_key(tab)]
end

local function panes_valid(panes)
  return panes and valid_win(panes.message_win) and valid_win(panes.input_win) and valid_win(panes.status_win)
end

local function set_current_panes(panes)
  state.message_win = panes and panes.message_win or nil
  state.input_win = panes and panes.input_win or nil
  state.status_win = panes and panes.status_win or nil
end

local function sync_current_panes()
  local key = tab_key()
  local panes = state.tabs[key]
  if panes and not panes_valid(panes) then
    state.tabs[key] = nil
    panes = nil
  end
  set_current_panes(panes)
  return panes
end

local function any_panes_visible()
  for key, panes in pairs(state.tabs) do
    if panes_valid(panes) then
      return true, key, panes
    end
    state.tabs[key] = nil
  end
  return false
end

local function layout()
  local cfg = config.get().ui
  local total_width = math.floor(vim.o.columns * cfg.width)
  local total_height = cfg.height and math.floor((vim.o.lines - vim.o.cmdheight) * cfg.height) or nil
  local input_height = cfg.input_height
  return cfg, math.max(total_width, 32), input_height, total_height
end

local function set_panel_win_options(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winbar = ""
  vim.wo[win].statusline = ""
end

local function set_buf_options(buf, filetype, name)
  if name and vim.api.nvim_buf_get_name(buf) == "" then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype or ""
end

local function leave_visual_mode()
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" or mode == "\19" then
    vim.cmd("normal! \027")
  end
end

local function ensure_buffers()
  if not valid_buf(state.message_buf) then
    state.message_buf = vim.api.nvim_create_buf(false, true)
    set_buf_options(state.message_buf, "markdown", "opencode-chat://messages")
    vim.bo[state.message_buf].modifiable = false
    vim.keymap.set("n", "<Tab>", function()
      require("opencode_chat.ui").focus_input()
    end, { buffer = state.message_buf, silent = true, desc = "Focus opencode input" })
    vim.keymap.set("n", "q", function()
      require("opencode_chat").toggle()
    end, { buffer = state.message_buf, silent = true, desc = "Toggle opencode chat" })
    vim.keymap.set("n", "<C-c>", function()
      require("opencode_chat").cancel()
    end, { buffer = state.message_buf, silent = true, desc = "Cancel opencode request" })
    vim.keymap.set("n", "d", function()
      require("opencode_chat").remove_context_at_cursor()
    end, { buffer = state.message_buf, silent = true, desc = "Remove opencode context under cursor" })
    vim.keymap.set("n", "D", function()
      require("opencode_chat").clear_context()
    end, { buffer = state.message_buf, silent = true, desc = "Clear opencode context" })
  end
  if not valid_buf(state.status_buf) then
    state.status_buf = vim.api.nvim_create_buf(false, true)
    set_buf_options(state.status_buf, "opencode-status", "opencode-chat://status")
    vim.bo[state.status_buf].modifiable = false
  end
  if not valid_buf(state.input_buf) then
    state.input_buf = vim.api.nvim_create_buf(false, true)
    set_buf_options(state.input_buf, "markdown", "opencode-chat://input")
    vim.bo[state.input_buf].filetype = "markdown"
    vim.keymap.set("n", "<C-s>", function()
      require("opencode_chat").submit()
    end, { buffer = state.input_buf, silent = true, desc = "Submit opencode prompt" })
    vim.keymap.set("i", "<C-s>", function()
      require("opencode_chat").submit()
    end, { buffer = state.input_buf, silent = true, desc = "Submit opencode prompt" })
    vim.keymap.set("n", "<Tab>", function()
      require("opencode_chat.ui").focus_messages()
    end, { buffer = state.input_buf, silent = true, desc = "Focus opencode messages" })
    vim.keymap.set("i", "<Tab>", function()
      require("opencode_chat.ui").focus_messages()
    end, { buffer = state.input_buf, silent = true, desc = "Focus opencode messages" })
    vim.keymap.set("n", "<C-c>", function()
      require("opencode_chat").cancel()
    end, { buffer = state.input_buf, silent = true, desc = "Cancel opencode request" })
    vim.keymap.set("i", "<C-c>", function()
      require("opencode_chat").cancel()
    end, { buffer = state.input_buf, silent = true, desc = "Cancel opencode request" })
  end
end

local function open_windows()
  ensure_buffers()
  local key = tab_key()
  local existing = panes_for(key)
  if panes_valid(existing) then
    set_current_panes(existing)
    return
  end

  local cfg, width, input_height, total_height = layout()
  local previous = vim.api.nvim_get_current_win()
  local old_winminheight = vim.o.winminheight
  local old_equalalways = vim.o.equalalways
  vim.o.winminheight = 0
  vim.o.equalalways = false
  vim.cmd("botright vertical " .. width .. "new")
  local panes = {}
  panes.message_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panes.message_win, state.message_buf)
  vim.wo[panes.message_win].winfixwidth = true
  vim.wo[panes.message_win].wrap = true
  set_panel_win_options(panes.message_win)
  if total_height and total_height > 0 and total_height < vim.api.nvim_win_get_height(panes.message_win) then
    vim.api.nvim_win_set_height(panes.message_win, total_height)
  end

  vim.api.nvim_set_current_win(panes.message_win)
  vim.cmd("belowright " .. input_height .. "split")
  panes.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panes.input_win, state.input_buf)
  vim.wo[panes.input_win].winfixheight = true
  set_panel_win_options(panes.input_win)
  vim.api.nvim_win_set_height(panes.input_win, input_height)

  vim.api.nvim_set_current_win(panes.input_win)
  vim.cmd("belowright 1split")
  panes.status_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panes.status_win, state.status_buf)
  vim.wo[panes.status_win].winfixheight = true
  set_panel_win_options(panes.status_win)
  vim.api.nvim_win_set_height(panes.status_win, 1)

  if cfg.message_height and cfg.message_height > 0 and valid_win(panes.message_win) then
    pcall(vim.api.nvim_win_set_height, panes.message_win, cfg.message_height)
  end

  state.tabs[key] = panes
  set_current_panes(panes)

  vim.o.winminheight = old_winminheight
  vim.o.equalalways = old_equalalways

  if valid_win(previous) then
    pcall(vim.api.nvim_set_current_win, previous)
  end
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.state()
  return state
end

function M.render()
  if not valid_buf(state.message_buf) then
    return
  end

  M.render_status()

  local lines = { "# opencode-chat.nvim", "" }
  if #state.context > 0 then
    table.insert(lines, "## Context")
    for index, item in ipairs(state.context) do
      table.insert(lines, string.format("%d. %s", index, item.label))
    end
    table.insert(lines, "")
  end

  if #state.messages == 0 then
    table.insert(lines, "在下方输入区写问题，按 <C-s> 提交。")
    table.insert(lines, "Context 行可在消息区按 d 删除，按 D 清空。")
  else
    for _, msg in ipairs(state.messages) do
      table.insert(lines, "## " .. msg.role)
      table.insert(lines, "")
      local text = tostring(msg.text or "")
      for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        table.insert(lines, line)
      end
      table.insert(lines, "")
    end
  end

  set_lines(state.message_buf, lines)

  local last = math.max(vim.api.nvim_buf_line_count(state.message_buf), 1)
  for key, panes in pairs(state.tabs) do
    if panes_valid(panes) then
      pcall(vim.api.nvim_win_set_cursor, panes.message_win, { last, 0 })
      pcall(vim.api.nvim_win_call, panes.message_win, function()
        vim.cmd("normal! zb")
      end)
    else
      state.tabs[key] = nil
    end
  end
  sync_current_panes()
end

function M.render_status()
  if not valid_buf(state.status_buf) then
    return
  end
  local model = config.current_model()
  local line = string.format(" %s | %s/%s | %s ", state.status or "Idle", model.providerID or "?", model.modelID or "?", model.variant or "?")
  set_lines(state.status_buf, { line })
end

function M.show(opts)
  opts = opts or {}
  state.visible = true
  if opts.focus ~= "none" or opts.leave_visual then
    leave_visual_mode()
  end
  open_windows()
  M.render()
  if opts.focus == "messages" then
    vim.api.nvim_set_current_win(state.message_win)
    pcall(vim.cmd, "stopinsert")
  elseif opts.focus ~= "none" then
    vim.api.nvim_set_current_win(state.input_win)
    vim.cmd("startinsert")
  end
  return state
end

function M.set_status(text)
  state.status = text or "Idle"
  M.render_status()
end

function M.focus_messages()
  leave_visual_mode()
  open_windows()
  M.render()
  vim.api.nvim_set_current_win(state.message_win)
  pcall(vim.cmd, "stopinsert")
end

function M.focus_input()
  leave_visual_mode()
  open_windows()
  M.render()
  vim.api.nvim_set_current_win(state.input_win)
  vim.cmd("startinsert")
end

function M.hide()
  state.visible = false
  pcall(function()
    require("opencode_chat.picker").close()
  end)
  for _, panes in pairs(state.tabs) do
    if valid_win(panes.message_win) then
      pcall(vim.api.nvim_win_close, panes.message_win, true)
    end
    if valid_win(panes.status_win) then
      pcall(vim.api.nvim_win_close, panes.status_win, true)
    end
    if valid_win(panes.input_win) then
      pcall(vim.api.nvim_win_close, panes.input_win, true)
    end
  end
  state.tabs = {}
  state.message_win = nil
  state.status_win = nil
  state.input_win = nil
end

function M.show_current_tab_if_visible()
  if not state.visible then
    return false
  end
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local has_other_window = false
  for _, win in ipairs(wins) do
    if not is_chat_win(win) then
      has_other_window = true
      break
    end
  end
  if not has_other_window then
    return false
  end
  if panes_valid(sync_current_panes()) then
    return true
  end
  M.show({ focus = "none" })
  return true
end

function M.close_if_only_chat_windows()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local chat_count = 0
  local other_count = 0
  for _, win in ipairs(wins) do
    if is_chat_win(win) then
      chat_count = chat_count + 1
    else
      other_count = other_count + 1
    end
  end
  if chat_count == 0 or other_count > 0 then
    return false
  end

  pcall(function()
    require("opencode_chat.picker").close()
  end)
  if #vim.api.nvim_list_tabpages() > 1 then
    state.tabs[tab_key()] = nil
    local still_visible = any_panes_visible()
    state.visible = still_visible
    pcall(vim.cmd, "tabclose")
    sync_current_panes()
    return true
  end

  pcall(vim.cmd, "quitall!")
  return true
end

function M.is_chat_window(win)
  return is_chat_win(win)
end

function M.toggle()
  local panes = sync_current_panes()
  if panes_valid(panes) then
    local picker_state = require("opencode_chat.picker").state()
    if picker_state.buf and vim.api.nvim_buf_is_valid(picker_state.buf) then
      M.hide()
      return state
    end
    local current = vim.api.nvim_get_current_win()
    if current == panes.message_win or current == panes.input_win or current == panes.status_win then
      M.hide()
    else
      M.focus_input()
    end
  else
    M.show()
  end
  return state
end

function M.add_context(item, project_root, opts)
  opts = opts or {}
  for index, existing in ipairs(state.context) do
    if existing.label == item.label then
      state.context[index] = item
      state.context_root = project_root or state.context_root
      M.show({ focus = opts.focus or "input", leave_visual = opts.leave_visual })
      return false
    end
  end
  table.insert(state.context, item)
  state.context_root = project_root or state.context_root
  M.show({ focus = opts.focus or "input", leave_visual = opts.leave_visual })
  return true
end

function M.remove_context(index)
  index = tonumber(index)
  if not index or index < 1 or index > #state.context then
    return false
  end
  table.remove(state.context, index)
  if #state.context == 0 then
    state.context_root = nil
  end
  M.render()
  return true
end

function M.clear_context()
  state.context = {}
  state.context_root = nil
  M.render()
end

function M.context_index_at_cursor()
  if not valid_win(state.message_win) or vim.api.nvim_get_current_win() ~= state.message_win then
    return nil
  end
  local line = vim.api.nvim_get_current_line()
  return tonumber(line:match("^(%d+)%.%s+@"))
end

function M.consume_context()
  local items = state.context
  local project_root = state.context_root
  state.context = {}
  state.context_root = nil
  return items, project_root
end

function M.context_prompt(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    table.insert(out, item.label)
    if item.text and item.text ~= "" then
      table.insert(out, "```" .. (item.ft or ""))
      table.insert(out, item.text)
      table.insert(out, "```")
    end
  end
  return table.concat(out, "\n")
end

function M.add_message(role, text)
  table.insert(state.messages, { role = role, text = text })
  if any_panes_visible() then
    M.render()
  else
    M.show({ focus = "input" })
  end
end

function M.replace_last_if(role, old_text, new_role, new_text)
  local messages = state.messages
  if messages[#messages] and messages[#messages].role == role and messages[#messages].text == old_text then
    messages[#messages] = { role = new_role, text = new_text }
  else
    table.insert(messages, { role = new_role, text = new_text })
  end
  M.render()
end

function M.update_last(role, text)
  local messages = state.messages
  if messages[#messages] and messages[#messages].role == role then
    messages[#messages].text = text
  else
    table.insert(messages, { role = role, text = text })
  end
  M.render()
end

function M.mark_cancelling()
  local messages = state.messages
  local last = messages[#messages]
  if last and last.role == "Assistant" and (last.text == "Thinking..." or last.text == "Editing...") then
    messages[#messages] = { role = "System", text = "Cancelling..." }
  else
    table.insert(messages, { role = "System", text = "Cancelling..." })
  end
  M.render()
end

function M.input_text()
  if not valid_buf(state.input_buf) then
    return ""
  end
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), "\n"))
end

function M.set_input(text)
  ensure_buffers()
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
end

function M.clear_input()
  M.set_input("")
end

function M.clear()
  state.messages = {}
  state.context = {}
  state.context_root = nil
  M.render()
  M.clear_input()
end

function M.set_messages(messages)
  state.messages = messages or {}
  M.show({ focus = "messages" })
end

function M.close()
  M.hide()
  if valid_buf(state.message_buf) then
    vim.api.nvim_buf_delete(state.message_buf, { force = true })
  end
  if valid_buf(state.status_buf) then
    vim.api.nvim_buf_delete(state.status_buf, { force = true })
  end
  if valid_buf(state.input_buf) then
    vim.api.nvim_buf_delete(state.input_buf, { force = true })
  end
  state.message_buf = nil
  state.status_buf = nil
  state.input_buf = nil
end

return M
