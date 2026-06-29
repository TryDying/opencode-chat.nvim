local M = {}

local state = {
  win = nil,
  buf = nil,
  items = {},
  line_items = {},
  on_select = nil,
}

local function valid_win(win_id)
  return win_id and vim.api.nvim_win_is_valid(win_id)
end

local function valid_buf(buf_id)
  return buf_id and vim.api.nvim_buf_is_valid(buf_id)
end

function M.close()
  if valid_win(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if valid_buf(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
  state.items = {}
  state.line_items = {}
  state.on_select = nil
end

local function select_line(line)
  local item = state.line_items[line]
  if not item then
    return
  end
  local on_select = state.on_select
  M.close()
  if on_select then
    on_select(item)
  end
end

function M.show(opts)
  opts = opts or {}
  M.close()
  state.items = opts.items or {}
  state.on_select = opts.on_select
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].modifiable = false

  local lines = { opts.title or "Select", "" }
  state.line_items = {}
  local current_group
  for _, item in ipairs(state.items) do
    if item.group and item.group ~= current_group then
      current_group = item.group
      table.insert(lines, item.group)
    end
    local marker = item.selected and "✓ " or "  "
    table.insert(lines, marker .. item.label)
    state.line_items[#lines] = item
  end
  if #state.items == 0 then
    table.insert(lines, "(empty)")
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  local width = opts.width or math.min(64, math.max(36, math.floor(vim.o.columns * 0.5)))
  local height = opts.height or math.min(#lines + 2, math.max(8, math.floor(vim.o.lines * 0.45)))
  local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
  local col = math.max(math.floor((vim.o.columns - width) / 2), 0)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    title = " " .. (opts.title or "Select") .. " ",
    style = "minimal",
  })

  vim.keymap.set("n", "<CR>", function()
    select_line(vim.api.nvim_win_get_cursor(0)[1])
  end, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "q", M.close, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "<Esc>", M.close, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "<LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid == state.win then
      select_line(pos.line)
    end
  end, { buffer = state.buf, silent = true })
end

function M.state()
  return state
end

return M
