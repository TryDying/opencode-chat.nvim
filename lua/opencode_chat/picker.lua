local M = {}

local state = {
  win = nil,
  buf = nil,
  menu = nil,
  items = {},
  line_items = {},
  on_select = nil,
  actions = {},
}

local function valid_win(win_id)
  return win_id and vim.api.nvim_win_is_valid(win_id)
end

local function valid_buf(buf_id)
  return buf_id and vim.api.nvim_buf_is_valid(buf_id)
end

function M.close()
  if state.menu then
    pcall(function()
      state.menu:unmount()
    end)
  end
  if valid_win(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if valid_buf(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
  state.menu = nil
  state.items = {}
  state.line_items = {}
  state.on_select = nil
  state.actions = {}
end

local function item_at_cursor()
  if not valid_win(state.win) then
    return nil
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, state.win)
  if not ok then
    return nil
  end
  return state.line_items[cursor[1]]
end

local function run_action(key)
  local action = state.actions and state.actions[key]
  local item = item_at_cursor()
  if action and item then
    action(item)
  end
end

local function set_action_keymaps(buf)
  for key, _ in pairs(state.actions or {}) do
    vim.keymap.set("n", key, function()
      run_action(key)
    end, { buffer = buf, silent = true })
  end
end

local function show_nui(opts)
  local ok_menu, Menu = pcall(require, "nui.menu")
  if not ok_menu then
    return false
  end

  local lines = {}
  local current_group
  state.line_items = {}
  for _, item in ipairs(state.items) do
    if item.group and item.group ~= current_group then
      current_group = item.group
      table.insert(lines, Menu.separator(item.group))
    end
    table.insert(lines, Menu.item((item.selected and "✓ " or "  ") .. item.label, { value = item }))
    state.line_items[#lines] = item
  end
  if #lines == 0 then
    table.insert(lines, Menu.item("(empty)", { value = nil }))
  end

  local width = opts.width or math.min(64, math.max(36, math.floor(vim.o.columns * 0.5)))
  local height = opts.height or math.min(#lines + 2, math.max(8, math.floor(vim.o.lines * 0.45)))
  state.menu = Menu({
    position = "50%",
    size = { width = width, height = height },
    border = {
      style = "rounded",
      text = { top = " " .. (opts.title or "Select") .. " ", top_align = "center" },
    },
    win_options = { cursorline = true },
  }, {
    lines = lines,
    max_width = width - 4,
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close = { "q", "<Esc>", "<C-c>" },
      submit = { "<CR>", "<Space>" },
    },
    on_close = function()
      state.win = nil
      state.buf = nil
      state.menu = nil
    end,
    on_submit = function(item)
      local selected = item and item.value
      local on_select = state.on_select
      M.close()
      if selected and on_select then
        on_select(selected)
      end
    end,
  })
  state.menu:mount()
  state.win = state.menu.winid
  state.buf = state.menu.bufnr
  set_action_keymaps(state.buf)
  pcall(vim.cmd, "stopinsert")
  return true
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
  state.actions = opts.actions or {}
  if show_nui(opts) then
    return
  end
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
  vim.wo[state.win].cursorline = true

  vim.keymap.set("n", "<CR>", function()
    select_line(vim.api.nvim_win_get_cursor(0)[1])
  end, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "q", M.close, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "<Esc>", M.close, { buffer = state.buf, silent = true })
  set_action_keymaps(state.buf)
  vim.keymap.set("n", "<LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid == state.win then
      select_line(pos.line)
    end
  end, { buffer = state.buf, silent = true })
  for line, _ in pairs(state.line_items) do
    pcall(vim.api.nvim_win_set_cursor, state.win, { line, 0 })
    break
  end
  pcall(vim.cmd, "stopinsert")
end

function M.state()
  return state
end

function M.current_item()
  return item_at_cursor()
end

function M.run_action(key)
  run_action(key)
end

return M
