local M = {}

local state = {
  file = nil,
  original = nil,
  updated = nil,
  patch = nil,
  buf_id = nil,
  win_id = nil,
}

local function split_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function parse_hunk_header(line)
  local old_start, _old_count, new_start = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?%d* @@")
  return tonumber(old_start), tonumber(new_start)
end

function M.apply_unified(original_lines, patch)
  local patch_lines = split_lines(patch)
  local result = {}
  local old_index = 1
  local i = 1

  while i <= #patch_lines do
    local line = patch_lines[i]
    if line:sub(1, 2) == "@@" then
      local old_start = parse_hunk_header(line)
      if not old_start then
        error("invalid unified diff hunk: " .. line)
      end
      while old_index < old_start do
        table.insert(result, original_lines[old_index])
        old_index = old_index + 1
      end
      i = i + 1
      while i <= #patch_lines and patch_lines[i]:sub(1, 2) ~= "@@" do
        local marker = patch_lines[i]:sub(1, 1)
        local content = patch_lines[i]:sub(2)
        if marker == " " then
          table.insert(result, original_lines[old_index] or content)
          old_index = old_index + 1
        elseif marker == "-" then
          old_index = old_index + 1
        elseif marker == "+" then
          table.insert(result, content)
        elseif marker == "\\" then
          -- no newline marker
        end
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  while old_index <= #original_lines do
    table.insert(result, original_lines[old_index])
    old_index = old_index + 1
  end

  return result
end

local function valid_win(win_id)
  return win_id and vim.api.nvim_win_is_valid(win_id)
end

local function valid_buf(buf_id)
  return buf_id and vim.api.nvim_buf_is_valid(buf_id)
end

function M.preview(file, patch)
  local original = vim.fn.readfile(file)
  local ok, updated = pcall(M.apply_unified, original, patch)
  if not ok then
    error(updated)
  end

  state.file = file
  state.original = original
  state.updated = updated
  state.patch = patch

  if not valid_buf(state.buf_id) then
    state.buf_id = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf_id].filetype = "diff"
    vim.bo[state.buf_id].bufhidden = "wipe"
  end
  vim.api.nvim_buf_set_lines(state.buf_id, 0, -1, false, split_lines(patch))
  if not valid_win(state.win_id) then
    local width = math.floor(vim.o.columns * 0.9)
    local height = math.floor((vim.o.lines - vim.o.cmdheight) * 0.75)
    state.win_id = vim.api.nvim_open_win(state.buf_id, true, {
      relative = "editor",
      width = width,
      height = height,
      row = 1,
      col = math.floor((vim.o.columns - width) / 2),
      border = "rounded",
      title = " opencode edit preview (:OpencodeApply / :OpencodeReject) ",
      style = "minimal",
    })
  end
  return state
end

function M.apply()
  if not state.file or not state.updated then
    error("no opencode edit preview to apply")
  end
  vim.fn.writefile(state.updated, state.file)
  M.reject()
end

function M.reject()
  if valid_win(state.win_id) then
    vim.api.nvim_win_close(state.win_id, true)
  end
  if valid_buf(state.buf_id) then
    vim.api.nvim_buf_delete(state.buf_id, { force = true })
  end
  state.file = nil
  state.original = nil
  state.updated = nil
  state.patch = nil
  state.buf_id = nil
  state.win_id = nil
end

function M.state()
  return state
end

return M
