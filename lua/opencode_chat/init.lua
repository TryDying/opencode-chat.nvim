local config = require("opencode_chat.config")
local server = require("opencode_chat.server")
local ui = require("opencode_chat.ui")
local context = require("opencode_chat.context")
local commands = require("opencode_chat.commands")
local diff = require("opencode_chat.diff")

local M = {}

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

  local prompt, project_root = build_prompt(text)
  ui.add_message("User", prompt)
  ui.add_message("Assistant", "Thinking...")

  server.send(prompt, project_root, function(ok, reply, err)
    vim.schedule(function()
      if ok then
        ui.replace_last_if("Assistant", "Thinking...", "Assistant", reply ~= "" and reply or "(empty response)")
      else
        ui.replace_last_if("Assistant", "Thinking...", "Error", tostring(err or "opencode request failed"))
      end
    end)
  end)
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
  instruction = instruction ~= "" and instruction or "Modify the current file. Return only a unified diff."
  local item, project_root = context.file_item(0)
  local prompt = table.concat({
    "You are editing a file. Return only a unified diff patch for the file below.",
    "Do not include Markdown fences or explanations.",
    "File: " .. item.relative,
    "Instruction: " .. instruction,
    "Current content:",
    "```" .. (item.ft or ""),
    item.text,
    "```",
  }, "\n")

  ui.add_message("User", "/edit " .. instruction)
  ui.add_message("Assistant", "Generating diff...")
  server.send(prompt, project_root, function(ok, reply, err)
    vim.schedule(function()
      if not ok then
        ui.replace_last_if("Assistant", "Generating diff...", "Error", tostring(err or "opencode edit failed"))
        return
      end
      local patch = reply:gsub("^```diff%s*", ""):gsub("```%s*$", "")
      local preview_ok, preview_err = pcall(diff.preview, item.path, patch)
      if preview_ok then
        ui.replace_last_if("Assistant", "Generating diff...", "Assistant", "Diff preview ready. Use :OpencodeApply or :OpencodeReject.")
      else
        ui.replace_last_if("Assistant", "Generating diff...", "Error", tostring(preview_err))
      end
    end)
  end)
end

function M.apply()
  diff.apply()
end

function M.reject()
  diff.reject()
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

M._build_prompt = build_prompt

return M
