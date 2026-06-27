local config = require("opencode_chat.config")
local port = require("opencode_chat.port")
local root = require("opencode_chat.root")

local M = {}

local state = {
  root = nil,
  port = nil,
  job_id = nil,
  win_id = nil,
  buf_id = nil,
  started = false,
}

local function valid_win(win_id)
  return win_id and vim.api.nvim_win_is_valid(win_id)
end

local function valid_buf(buf_id)
  return buf_id and vim.api.nvim_buf_is_valid(buf_id)
end

local function job_running(job_id)
  return job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function open_float(buf_id)
  local cfg = config.get().terminal
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

function M.is_visible()
  return valid_win(state.win_id)
end

function M.ensure_started(startpath)
  local cfg = config.get()

  if state.started and valid_buf(state.buf_id) and job_running(state.job_id) then
    if not valid_win(state.win_id) then
      state.win_id = open_float(state.buf_id)
    end
    return state
  end

  state.root = root.find(startpath)
  state.port = cfg.port or port.pick(cfg.host)
  state.buf_id = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf_id].bufhidden = "hide"
  vim.bo[state.buf_id].filetype = "opencode-chat"
  state.win_id = open_float(state.buf_id)

  local cmd = { cfg.command, "--port", tostring(state.port) }
  state.job_id = vim.fn.termopen(cmd, {
    cwd = state.root,
    on_exit = function()
      state.started = false
      state.job_id = nil
    end,
  })

  if state.job_id <= 0 then
    error("failed to start opencode: " .. cfg.command)
  end

  state.started = true
  vim.cmd("startinsert")
  return state
end

function M.show()
  if valid_win(state.win_id) then
    vim.api.nvim_set_current_win(state.win_id)
  elseif valid_buf(state.buf_id) then
    state.win_id = open_float(state.buf_id)
  else
    M.ensure_started()
  end
  vim.cmd("startinsert")
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
    return state
  end

  M.ensure_started()
  vim.cmd("startinsert")
  return state
end

function M.stop()
  if valid_win(state.win_id) then
    vim.api.nvim_win_close(state.win_id, true)
  end
  if job_running(state.job_id) then
    vim.fn.jobstop(state.job_id)
  end
  if valid_buf(state.buf_id) then
    vim.api.nvim_buf_delete(state.buf_id, { force = true })
  end

  state.root = nil
  state.port = nil
  state.job_id = nil
  state.win_id = nil
  state.buf_id = nil
  state.started = false
end

function M.new_session()
  M.stop()
  return M.ensure_started()
end

return M
