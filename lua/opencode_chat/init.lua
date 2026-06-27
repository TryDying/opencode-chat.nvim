local config = require("opencode_chat.config")
local server = require("opencode_chat.server")
local ui = require("opencode_chat.ui")
local context = require("opencode_chat.context")
local commands = require("opencode_chat.commands")

local M = {}

local function notify_error(message)
  vim.schedule(function()
    vim.notify(message, vim.log.levels.ERROR)
  end)
end

local function prompt_text(text)
  local refs, project_root = ui.consume_context()
  if #refs == 0 then
    return text, project_root
  end
  return table.concat(refs, "\n") .. "\n\n" .. text, project_root
end

local function set_default_keymaps()
  local opts = { noremap = true, silent = true }
  vim.keymap.set("n", "<M-->", function()
    require("opencode_chat").toggle()
  end, vim.tbl_extend("force", opts, { desc = "Toggle opencode chat" }))
  vim.keymap.set("v", "<M-->", function()
    require("opencode_chat").append_selection()
  end, vim.tbl_extend("force", opts, { desc = "Append selection to opencode chat" }))
end

function M.setup(opts)
  local cfg = config.setup(opts)
  commands.setup(M)
  if cfg.keymaps then
    set_default_keymaps()
  end
  return M
end

function M.toggle()
  return ui.toggle()
end

function M.show()
  return ui.show()
end

function M.ask(text)
  if not text or text == "" then
    vim.ui.input({ prompt = "opencode> " }, function(input)
      if input and input ~= "" then
        M.ask(input)
      end
    end)
    return
  end

  local full_prompt, project_root = prompt_text(text)
  ui.add_message("User", full_prompt)
  ui.add_message("Assistant", "Thinking...")

  server.send(full_prompt, project_root, function(ok, reply, err)
    vim.schedule(function()
      local messages = ui.state().messages
      if messages[#messages] and messages[#messages].text == "Thinking..." then
        table.remove(messages, #messages)
      end
      if ok then
        ui.add_message("Assistant", reply ~= "" and reply or "(empty response)")
      else
        ui.add_message("Error", tostring(err or "opencode request failed"))
      end
    end)
  end)
end

function M.append_file()
  local ref, project_root = context.file_reference(0)
  ui.add_context(ref, project_root)
end

function M.append_selection()
  local ref, project_root = context.selection_reference(0)
  ui.add_context(ref, project_root)
end

function M.new_session()
  ui.clear()
  server.new_session(function(ok, _state, err)
    if not ok then
      notify_error("opencode new session failed: " .. tostring(err))
    end
  end)
end

function M.stop()
  server.stop()
  ui.close()
end

M._prompt_text = prompt_text

return M
