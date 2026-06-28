local config = require("opencode_chat.config")
local server = require("opencode_chat.server")
local ui = require("opencode_chat.ui")
local context = require("opencode_chat.context")
local commands = require("opencode_chat.commands")

local M = {}
local request = {
  busy = false,
  id = 0,
}

local function notify_error(message)
  vim.schedule(function()
    vim.notify(message, vim.log.levels.ERROR)
  end)
end

local function build_prompt(text)
  local items, project_root = ui.consume_context()
  local context_text = ui.context_prompt(items)
  if context_text == "" then
    return text, project_root
  end
  return context_text .. "\n\n" .. text, project_root
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

function M.submit()
  if request.busy then
    notify_error("opencode is still responding; use <C-c> or :OpencodeCancel first")
    return
  end
  local text = ui.input_text()
  if text == "" then
    notify_error("opencode prompt is empty")
    return
  end
  ui.clear_input()
  M.ask(text)
end

function M.ask(text)
  if not text or text == "" then
    ui.show()
    return
  end

  if request.busy then
    notify_error("opencode is still responding; use <C-c> or :OpencodeCancel first")
    return
  end

  local prompt, project_root = build_prompt(text)
  request.busy = true
  request.id = request.id + 1
  local request_id = request.id
  ui.add_message("User", prompt)
  ui.add_message("Assistant", "Thinking...")

  server.send(prompt, project_root, function(ok, reply, err)
    vim.schedule(function()
      if request_id ~= request.id then
        return
      end
      request.busy = false
      if ok then
        ui.replace_last_if("Assistant", "Thinking...", "Assistant", reply ~= "" and reply or "(empty response)")
      else
        ui.replace_last_if("Assistant", "Thinking...", "Error", tostring(err or "opencode request failed"))
      end
    end)
  end)
end

function M.cancel()
  if not request.busy then
    notify_error("no active opencode request")
    return
  end
  request.id = request.id + 1
  request.busy = false
  server.cancel()
  ui.replace_last_if("Assistant", "Thinking...", "Cancelled", "Request cancelled.")
  ui.replace_last_if("Assistant", "Editing...", "Cancelled", "Request cancelled.")
end

function M.append_file()
  local item, project_root = context.file_item(0)
  ui.add_context(item, project_root)
end

function M.append_selection()
  local item, project_root = context.selection_item(0)
  ui.add_context(item, project_root)
end

function M.edit(instruction)
  if request.busy then
    notify_error("opencode is still responding; use <C-c> or :OpencodeCancel first")
    return
  end
  instruction = instruction ~= "" and instruction or "Modify the current file as requested."
  local item, project_root = context.file_item(0)
  local prompt = table.concat({
    "You are editing a file in the current project.",
    "Use the configured opencode agent to make the change directly when appropriate.",
    "After editing, summarize what changed.",
    "File: " .. item.relative,
    "Instruction: " .. instruction,
    "Current content:",
    "```" .. (item.ft or ""),
    item.text,
    "```",
  }, "\n")

  ui.add_message("User", "/edit " .. instruction)
  ui.add_message("Assistant", "Editing...")
  request.busy = true
  request.id = request.id + 1
  local request_id = request.id
  server.send(prompt, project_root, function(ok, reply, err)
    vim.schedule(function()
      if request_id ~= request.id then
        return
      end
      request.busy = false
      if not ok then
        ui.replace_last_if("Assistant", "Editing...", "Error", tostring(err or "opencode edit failed"))
        return
      end
      ui.replace_last_if("Assistant", "Editing...", "Assistant", reply ~= "" and reply or "(edit completed)")
    end)
  end)
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
  request.busy = false
  request.id = request.id + 1
  server.stop()
  ui.close()
end

M._build_prompt = build_prompt
M._request = request

return M
