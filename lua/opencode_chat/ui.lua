local config = require("opencode_chat.config")

local M = {}

local state = {
  message_win = nil,
  input_win = nil,
  message_buf = nil,
  input_buf = nil,
  messages = {},
  context = {},
  context_root = nil,
  action_line = 3,
  actions = {},
}

local function valid_win(win_id)
  return win_id and vim.api.nvim_win_is_valid(win_id)
end

local function valid_buf(buf_id)
  return buf_id and vim.api.nvim_buf_is_valid(buf_id)
end

local function layout()
  local cfg = config.get().ui
  local total_width = math.floor(vim.o.columns * cfg.width)
  local total_height = math.floor((vim.o.lines - vim.o.cmdheight) * cfg.height)
  local input_height = cfg.input_height
  local message_height = total_height - input_height - 2
  local row = math.max(math.floor((vim.o.lines - total_height) / 2) - 1, 0)
  local col = math.max(math.floor((vim.o.columns - total_width) / 2), 0)
  return cfg, total_width, message_height, input_height, row, col
end

local function ensure_buffers()
  if not valid_buf(state.message_buf) then
    state.message_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.message_buf].bufhidden = "hide"
    vim.bo[state.message_buf].filetype = "markdown"
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
    vim.keymap.set("n", "<LeftMouse>", function()
      require("opencode_chat.ui").click_action()
    end, { buffer = state.message_buf, silent = true, desc = "opencode chat action" })
  end
  if not valid_buf(state.input_buf) then
    state.input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.input_buf].bufhidden = "hide"
    vim.bo[state.input_buf].filetype = "markdown"
    vim.bo[state.input_buf].buftype = "acwrite"
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
  local cfg, width, message_height, input_height, row, col = layout()
  if not valid_win(state.message_win) then
    state.message_win = vim.api.nvim_open_win(state.message_buf, true, {
      relative = "editor",
      width = width,
      height = message_height,
      row = row,
      col = col,
      border = cfg.border,
      title = cfg.title,
      style = "minimal",
    })
  end
  if not valid_win(state.input_win) then
    state.input_win = vim.api.nvim_open_win(state.input_buf, true, {
      relative = "editor",
      width = width,
      height = input_height,
      row = row + message_height + 2,
      col = col,
      border = cfg.border,
      title = cfg.input_title,
      style = "minimal",
    })
  end
end

function M.state()
  return state
end

function M.render()
  if not valid_buf(state.message_buf) then
    return
  end

  local lines = { "# opencode-chat.nvim", "" }
  local action_text = "[Sessions] [New Session] [Model] [Variant]"
  state.action_line = #lines + 1
  state.actions = {
    { label = "Sessions", start_col = 1, end_col = 10, action = "sessions" },
    { label = "New Session", start_col = 12, end_col = 24, action = "new_session" },
    { label = "Model", start_col = 26, end_col = 32, action = "model" },
    { label = "Variant", start_col = 34, end_col = 42, action = "variant" },
  }
  table.insert(lines, action_text)
  table.insert(lines, "")
  if #state.context > 0 then
    table.insert(lines, "## Context")
    for _, item in ipairs(state.context) do
      table.insert(lines, "- " .. item.label)
    end
    table.insert(lines, "")
  end

  if #state.messages == 0 then
    table.insert(lines, "在下方输入区写问题，按 <C-s> 提交。")
    table.insert(lines, "Visual <M--> 可加入选区上下文。")
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

  vim.bo[state.message_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.message_buf, 0, -1, false, lines)
  vim.bo[state.message_buf].modifiable = false

  if valid_win(state.message_win) then
    local last = math.max(vim.api.nvim_buf_line_count(state.message_buf), 1)
    pcall(vim.api.nvim_win_set_cursor, state.message_win, { last, 0 })
    pcall(vim.api.nvim_win_call, state.message_win, function()
      vim.cmd("normal! zb")
    end)
  end
end

function M.click_action()
  local pos = vim.fn.getmousepos()
  if pos.winid ~= state.message_win or pos.line ~= state.action_line then
    return
  end
  for _, action in ipairs(state.actions) do
    if pos.column >= action.start_col and pos.column <= action.end_col then
      local api = require("opencode_chat")
      if action.action == "sessions" then
        api.show_sessions()
      elseif action.action == "new_session" then
        api.new_session()
      elseif action.action == "model" then
        api.show_models()
      elseif action.action == "variant" then
        api.show_variants()
      end
      return
    end
  end
end

function M.show(opts)
  opts = opts or {}
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

function M.focus_messages()
  open_windows()
  M.render()
  vim.api.nvim_set_current_win(state.message_win)
  pcall(vim.cmd, "stopinsert")
end

function M.focus_input()
  open_windows()
  M.render()
  vim.api.nvim_set_current_win(state.input_win)
  vim.cmd("startinsert")
end

function M.hide()
  pcall(function()
    require("opencode_chat.picker").close()
  end)
  if valid_win(state.message_win) then
    vim.api.nvim_win_close(state.message_win, true)
  end
  if valid_win(state.input_win) then
    vim.api.nvim_win_close(state.input_win, true)
  end
  state.message_win = nil
  state.input_win = nil
end

function M.toggle()
  if valid_win(state.message_win) or valid_win(state.input_win) then
    M.hide()
  else
    M.show()
  end
  return state
end

function M.add_context(item, project_root)
  table.insert(state.context, item)
  state.context_root = project_root or state.context_root
  M.show({ focus = "input" })
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
  if valid_win(state.message_win) or valid_win(state.input_win) then
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
  if valid_buf(state.input_buf) then
    vim.api.nvim_buf_delete(state.input_buf, { force = true })
  end
  state.message_buf = nil
  state.input_buf = nil
end

return M
