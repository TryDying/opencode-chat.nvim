local config = require("opencode_chat.config")
local terminal = require("opencode_chat.terminal")
local client = require("opencode_chat.client")
local context = require("opencode_chat.context")
local commands = require("opencode_chat.commands")

local M = {}

local function append(text, project_root)
  local cfg = config.get()
  local state = terminal.ensure_started(project_root)
  terminal.show()

  if cfg.append_newline then
    text = text .. "\n"
  end

  client.wait_until_ready({ host = cfg.host, port = state.port }, function(ok, result)
    if not ok then
      vim.schedule(function()
        vim.notify("opencode is not ready: " .. (result and (result.stderr or result.stdout) or "timeout"), vim.log.levels.ERROR)
      end)
      return
    end

    client.append_prompt(text, { host = cfg.host, port = state.port })
  end)
end

function M.setup(opts)
  config.setup(opts)
  commands.setup(M)
  return M
end

function M.toggle()
  return terminal.toggle()
end

function M.append_file()
  local ref, project_root = context.file_reference(0)
  append(ref, project_root)
end

function M.append_selection()
  local ref, project_root = context.selection_reference(0)
  append(ref, project_root)
end

function M.new_session()
  return terminal.new_session()
end

function M.stop()
  return terminal.stop()
end

M._append = append

return M
