local config = require("opencode_chat.config")

local M = {}

local state = {
  visible = false,
  message_buf = nil,
  input_buf = nil,
  status_buf = nil,
  message_win = nil,
  input_win = nil,
  status_win = nil,
  messages = {},
  context = {},
  context_root = nil,
  status = "Idle",
}

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function set_buf_options(buf, filetype, name)
  if name and vim.api.nvim_buf_get_name(buf) == "" then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype or ""
end

local function set_float_options(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winbar = ""
  vim.wo[win].statusline = ""
  vim.wo[win].wrap = true
end

local function geometry()
  local width = math.max(math.floor(vim.o.columns * 0.52), 44)
  local height = math.max(math.floor(vim.o.lines * 0.42), 12)
  width = math.min(width, math.max(vim.o.columns - 4, 20))
  height = math.min(height, math.max(vim.o.lines - vim.o.cmdheight - 4, 8))
  local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
  local col = math.max(math.floor((vim.o.columns - width) / 2), 0)
  return {
    relative = "editor",
    style = "minimal",
    border = config.get().ui.border or "rounded",
    row = row,
    col = col,
    width = width,
    height = height,
  }
end

local function ensure_buffers()
  if not valid_buf(state.message_buf) then
    state.message_buf = vim.api.nvim_create_buf(false, true)
    set_buf_options(state.message_buf, "markdown", "opencode-chat://quick-messages")
    vim.bo[state.message_buf].modifiable = false
    vim.keymap.set("n", "q", function()
      require("opencode_chat.quick").close()
    end, { buffer = state.message_buf, silent = true, desc = "Close opencode quick ask" })
    vim.keymap.set("n", "<Tab>", function()
      require("opencode_chat.quick_ui").focus_input()
    end, { buffer = state.message_buf, silent = true, desc = "Focus opencode quick input" })
    vim.keymap.set("n", "<C-c>", function()
      require("opencode_chat.quick").cancel()
    end, { buffer = state.message_buf, silent = true, desc = "Cancel opencode quick ask" })
    vim.keymap.set("n", "d", function()
      require("opencode_chat.quick").remove_context_at_cursor()
    end, { buffer = state.message_buf, silent = true, desc = "Remove opencode quick context" })
    vim.keymap.set("n", "D", function()
      require("opencode_chat.quick").clear_context()
    end, { buffer = state.message_buf, silent = true, desc = "Clear opencode quick context" })
  end
  if not valid_buf(state.input_buf) then
    state.input_buf = vim.api.nvim_create_buf(false, true)
    set_buf_options(state.input_buf, "markdown", "opencode-chat://quick-input")
    vim.keymap.set({ "n", "i" }, "<C-s>", function()
      require("opencode_chat.quick").submit()
    end, { buffer = state.input_buf, silent = true, desc = "Submit opencode quick ask" })
    vim.keymap.set({ "n", "i" }, "<C-c>", function()
      require("opencode_chat.quick").cancel()
    end, { buffer = state.input_buf, silent = true, desc = "Cancel opencode quick ask" })
    vim.keymap.set({ "n", "i" }, "<Tab>", function()
      require("opencode_chat.quick_ui").focus_messages()
    end, { buffer = state.input_buf, silent = true, desc = "Focus opencode quick messages" })
  end
  if not valid_buf(state.status_buf) then
    state.status_buf = vim.api.nvim_create_buf(false, true)
    set_buf_options(state.status_buf, "opencode-status", "opencode-chat://quick-status")
    vim.bo[state.status_buf].modifiable = false
  end
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function open_windows()
  ensure_buffers()
  if valid_win(state.message_win) and valid_win(state.input_win) and valid_win(state.status_win) then
    return
  end
  local g = geometry()
  local message_height = math.max(g.height - 7, 5)
  state.message_win = vim.api.nvim_open_win(state.message_buf, false, vim.tbl_extend("force", g, {
    height = message_height,
    title = " Quick Ask ",
    title_pos = "center",
  }))
  state.input_win = vim.api.nvim_open_win(state.input_buf, false, vim.tbl_extend("force", g, {
    row = g.row + message_height + 2,
    height = 3,
    title = " prompt (<C-s> submit) ",
  }))
  state.status_win = vim.api.nvim_open_win(state.status_buf, false, vim.tbl_extend("force", g, {
    row = g.row + message_height + 6,
    height = 1,
    border = "none",
  }))
  set_float_options(state.message_win)
  set_float_options(state.input_win)
  set_float_options(state.status_win)
end

function M.state()
  return state
end

function M.render_status()
  if not valid_buf(state.status_buf) then
    return
  end
  local model = config.current_model()
  set_lines(state.status_buf, {
    string.format(" %s | %s/%s | %s | q close ", state.status or "Idle", model.providerID or "?", model.modelID or "?", model.variant or "?"),
  })
end

function M.render()
  if not valid_buf(state.message_buf) then
    return
  end
  M.render_status()
  local lines = { "# Quick Ask", "" }
  if #state.context > 0 then
    table.insert(lines, "## Context")
    for index, item in ipairs(state.context) do
      table.insert(lines, string.format("%d. %s", index, item.label))
    end
    table.insert(lines, "")
  end
  if #state.messages == 0 then
    table.insert(lines, "临时答疑窗口：按 <C-s> 提交，按 q 关闭。")
    table.insert(lines, "关闭后会删除本次临时 session。")
  else
    for _, msg in ipairs(state.messages) do
      table.insert(lines, "## " .. msg.role)
      table.insert(lines, "")
      for _, line in ipairs(vim.split(tostring(msg.text or ""), "\n", { plain = true })) do
        table.insert(lines, line)
      end
      table.insert(lines, "")
    end
  end
  set_lines(state.message_buf, lines)
  if valid_win(state.message_win) then
    local last = math.max(vim.api.nvim_buf_line_count(state.message_buf), 1)
    pcall(vim.api.nvim_win_set_cursor, state.message_win, { last, 0 })
  end
end

function M.show(opts)
  opts = opts or {}
  state.visible = true
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

function M.focus_input()
  M.show()
end

function M.focus_messages()
  M.show({ focus = "messages" })
end

function M.set_status(text)
  state.status = text or "Idle"
  M.render_status()
end

function M.hide()
  state.visible = false
  for _, win in ipairs({ state.message_win, state.input_win, state.status_win }) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  state.message_win = nil
  state.input_win = nil
  state.status_win = nil
end

function M.close()
  M.hide()
  for _, buf in ipairs({ state.message_buf, state.input_buf, state.status_buf }) do
    if valid_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  state.message_buf = nil
  state.input_buf = nil
  state.status_buf = nil
  state.messages = {}
  state.context = {}
  state.context_root = nil
  state.status = "Idle"
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

function M.add_message(role, text)
  table.insert(state.messages, { role = role, text = text })
  M.show({ focus = "input" })
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
  M.replace_last_if("Assistant", "Thinking...", "System", "Cancelling...")
end

function M.add_context(item, project_root, opts)
  opts = opts or {}
  for index, existing in ipairs(state.context) do
    if existing.label == item.label then
      state.context[index] = item
      state.context_root = project_root or state.context_root
      M.show({ focus = opts.focus or "input" })
      return false
    end
  end
  table.insert(state.context, item)
  state.context_root = project_root or state.context_root
  M.show({ focus = opts.focus or "input" })
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

function M.context_index_at_cursor()
  if not valid_win(state.message_win) or vim.api.nvim_get_current_win() ~= state.message_win then
    return nil
  end
  return tonumber(vim.api.nvim_get_current_line():match("^(%d+)%.%s+@"))
end

function M.clear_context()
  state.context = {}
  state.context_root = nil
  M.render()
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

return M
