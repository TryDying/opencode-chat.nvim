local config = require("opencode_chat.config")

local M = {}

local state = {
  win_id = nil,
  buf_id = nil,
  messages = {},
  context = {},
  context_root = nil,
}

local function valid_win(win_id)
  return win_id and vim.api.nvim_win_is_valid(win_id)
end

local function valid_buf(buf_id)
  return buf_id and vim.api.nvim_buf_is_valid(buf_id)
end

local function open_float(buf_id)
  local cfg = config.get().ui
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width = math.floor(columns * cfg.width)
  local height = math.floor((lines - vim.o.cmdheight) * cfg.height)
  local row = math.floor((lines - height) / 2) - 1
  local col = math.floor((columns - width) / 2)

  return vim.api.nvim_open_win(buf_id, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(row, 0),
    col = math.max(col, 0),
    border = cfg.border,
    title = cfg.title,
    style = "minimal",
  })
end

function M.state()
  return state
end

function M.render()
  if not valid_buf(state.buf_id) then
    return
  end

  local lines = { "# opencode-chat.nvim", "" }
  if #state.context > 0 then
    table.insert(lines, "## Context")
    for _, item in ipairs(state.context) do
      table.insert(lines, "- " .. item)
    end
    table.insert(lines, "")
  end

  if #state.messages == 0 then
    table.insert(lines, "Use :OpencodeAsk to send a prompt.")
    table.insert(lines, "Use Visual <M--> or :OpencodeAppendSelection to add context.")
  else
    for _, msg in ipairs(state.messages) do
      table.insert(lines, "## " .. msg.role)
      table.insert(lines, "")
      for line in tostring(msg.text):gmatch("([^\n]*)\n?") do
        if line == "" and #lines > 0 and lines[#lines] == "" then
          -- keep output compact
        else
          table.insert(lines, line)
        end
      end
      table.insert(lines, "")
    end
  end

  vim.bo[state.buf_id].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_id, 0, -1, false, lines)
  vim.bo[state.buf_id].modifiable = false
end

function M.show()
  if not valid_buf(state.buf_id) then
    state.buf_id = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf_id].bufhidden = "hide"
    vim.bo[state.buf_id].filetype = "markdown"
    vim.bo[state.buf_id].modifiable = false
  end
  if not valid_win(state.win_id) then
    state.win_id = open_float(state.buf_id)
  else
    vim.api.nvim_set_current_win(state.win_id)
  end
  M.render()
  return state
end

function M.hide()
  if valid_win(state.win_id) then
    vim.api.nvim_win_close(state.win_id, true)
    state.win_id = nil
  end
end

function M.toggle()
  if valid_win(state.win_id) then
    M.hide()
  else
    M.show()
  end
  return state
end

function M.add_context(ref, project_root)
  table.insert(state.context, ref)
  state.context_root = project_root or state.context_root
  M.show()
end

function M.consume_context()
  local items = state.context
  local project_root = state.context_root
  state.context = {}
  state.context_root = nil
  return items, project_root
end

function M.add_message(role, text)
  table.insert(state.messages, { role = role, text = text })
  M.show()
end

function M.clear()
  state.messages = {}
  state.context = {}
  state.context_root = nil
  M.render()
end

function M.close()
  M.hide()
  if valid_buf(state.buf_id) then
    vim.api.nvim_buf_delete(state.buf_id, { force = true })
  end
  state.buf_id = nil
end

return M
