local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd)
vim.cmd("runtime plugin/opencode_chat.lua")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s\nexpected: %s\nactual:   %s", message or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_true(value, message)
  if not value then
    error(message or "expected truthy value")
  end
end

local function wait_for(predicate, timeout_ms)
  local deadline = vim.loop.hrtime() + timeout_ms * 1000000
  while vim.loop.hrtime() < deadline do
    if predicate() then
      return true
    end
    vim.wait(50)
  end
  return false
end

assert_eq(vim.env.VIM_PROFILE, "basic", "tests must run with VIM_PROFILE=basic")

local root = require("opencode_chat.root")
local port = require("opencode_chat.port")
local client = require("opencode_chat.client")
local config = require("opencode_chat.config")
local context = require("opencode_chat.context")
local opencode = require("opencode_chat")
local picker = require("opencode_chat.picker")
local server = require("opencode_chat.server")
local ui = require("opencode_chat.ui")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/.git", "p")
vim.fn.mkdir(tmp .. "/src", "p")
local file = tmp .. "/src/example.lua"
vim.fn.writefile({
  "local M = {}",
  "",
  "function M.add(a, b)",
  "  return a + b",
  "end",
  "",
  "function M.mul(a, b)",
  "  return a * b",
  "end",
  "",
  "return M",
}, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))
vim.bo.filetype = "lua"

local fake_port = port.pick("127.0.0.1")
opencode.setup({
  command = cwd .. "/tests/fixtures/opencode",
  port = fake_port,
  startup_timeout_ms = 3000,
  response_timeout_ms = 3000,
  agent = "quick",
  model = "deepseek/deepseek-v4-flash",
  providers = {
    deepseek = {
      variants = { "low", "medium", "high", "max" },
      models = {
        { id = "deepseek-v4-flash", default_variant = "low" },
        { id = "deepseek-v4-pro", default_variant = "high" },
      },
    },
  },
  keymaps = {
    toggle = "<M-->",
    append_selection = "<M-->",
    sessions = "<leader>Xl",
    new_session = "<leader>Xn",
    rename_session = "<leader>Xr",
    models = "<leader>Xm",
    variants = "<leader>Xt",
  },
})

assert_true(vim.fn.exists(":OpencodeToggle") == 2, "plugin command should be loaded")
assert_true(vim.fn.exists(":OpencodeAsk") == 2, "ask command should be registered")
assert_true(vim.fn.exists(":OpencodeEdit") == 2, "edit command should be registered")
assert_true(vim.fn.exists(":OpencodeCancel") == 2, "cancel command should be registered")
assert_true(vim.fn.exists(":OpencodeSessions") == 2, "sessions command should be registered")
assert_true(vim.fn.exists(":OpencodeRenameSession") == 2, "rename session command should be registered")
assert_true(vim.fn.exists(":OpencodeModels") == 2, "models command should be registered")
assert_true(vim.fn.exists(":OpencodeVariants") == 2, "variants command should be registered")
assert_true(vim.fn.maparg("<M-->", "n") ~= "", "normal <M--> should be mapped")
assert_true(vim.fn.maparg("<M-->", "v") ~= "", "visual <M--> should be mapped")
assert_true(vim.fn.maparg("<leader>Xl", "n") ~= "", "session list keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xn", "n") ~= "", "new session keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xr", "n") ~= "", "rename session keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xm", "n") ~= "", "model picker keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xt", "n") ~= "", "variant picker keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xv", "n") == "", "old variant keymap should not be mapped")
assert_true(not pcall(function()
  config.setup({ variant = "low" })
end), "top-level variant config should be rejected")
assert_eq(config.current_model().modelID, "deepseek-v4-flash", "failed config setup should preserve current config")

assert_eq(root.find(file), vim.fs.normalize(tmp), "root.find should detect .git root")
assert_eq(root.relative(file, tmp), "src/example.lua", "root.relative should produce project-relative path")

local file_item, project_root = context.file_item(0)
assert_eq(project_root, vim.fs.normalize(tmp), "file_item should return project root")
assert_eq(file_item.label, "@src/example.lua", "file_item should use @relative/path")
assert_true(file_item.text:match("function M.add") ~= nil, "file_item should include buffer text")

vim.fn.setpos("'<", { 0, 5, 1, 0 })
vim.fn.setpos("'>", { 0, 3, 1, 0 })
local selection = context.selection_item(0)
assert_eq(selection.label, "@src/example.lua#L3-L5", "selection_item should sort reversed visual marks")
assert_eq(selection.text, "function M.add(a, b)\n  return a + b\nend", "selection_item should include selected text")

vim.fn.setpos("'<", { 0, 0, 0, 0 })
vim.fn.setpos("'>", { 0, 0, 0, 0 })
vim.cmd("normal! ggVjj")
assert_eq(context.selection_item(0).label, "@src/example.lua#L1-L3", "selection_item should fall back to active visual positions")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)

assert_eq(client.session_url({ host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/session", "session URL should prefer current API")
assert_eq(client.message_url("abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/session/abc/message", "message URL should prefer current API")
assert_eq(client.legacy_prompt_url("abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/api/session/abc/prompt", "legacy prompt URL should remain available")
assert_eq(client.abort_url("abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/session/abc/abort", "abort URL should target session abort API")
assert_eq(client.rename_session_url("abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/session/abc", "rename URL should target session update API")
assert_eq(client.project_sessions_url("project", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/project/project/session", "project sessions URL should target project-scoped sessions")
assert_eq(client.event_subscribe_url({ host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/event/subscribe", "event subscribe URL should target SSE endpoint")
assert_eq(client.extract_assistant_text({
  { info = { role = "user" }, parts = { { type = "text", text = "question" } } },
  { info = { role = "assistant" }, parts = { { type = "text", text = "answer" } } },
}), "answer", "extract_assistant_text should ignore user echo and read assistant text parts")
assert_eq(client.format_error({ status = 400, body = "bad request", stderr = "" }, "fallback"), "HTTP 400: bad request", "format_error should not let empty stderr hide HTTP body")

opencode.append_file()
assert_eq(ui.state().context[1].label, "@src/example.lua", "append_file should add structured context")
assert_true(ui.state().context[1].text:match("return a %+ b") ~= nil, "context should include code text")
assert_true(vim.api.nvim_win_is_valid(ui.state().status_win), "status window should exist")
assert_eq(vim.api.nvim_win_get_config(ui.state().message_win).relative, "", "chat message pane should be a normal split, not a float")
assert_true(vim.api.nvim_win_get_width(ui.state().message_win) <= math.ceil(vim.o.columns * 0.45), "chat panel should use the right-side configured width")
assert_true(ui.state().toolbar_win == nil, "toolbar window should be removed")
assert_true(vim.api.nvim_win_get_position(ui.state().status_win)[1] > vim.api.nvim_win_get_position(ui.state().input_win)[1], "status bar should be below input pane")

ui.set_input("这是啥")
opencode.submit()

local prompt_file = tmp .. "/.opencode-chat-prompt.jsonl"
local session_file = tmp .. "/.opencode-chat-session.jsonl"
assert_true(wait_for(function()
  return vim.fn.filereadable(prompt_file) == 1 and vim.fn.filereadable(session_file) == 1 and server.state().session_id == "test-session-1"
end, 5000), "submit should create session and send prompt to fake headless server")

local session_payload = vim.json.decode(vim.fn.readfile(session_file)[1])
assert_eq(session_payload.agent, "quick", "session create should include configured opencode agent")
assert_eq(session_payload.model.providerID, "deepseek", "session create model should include providerID")
assert_eq(session_payload.model.id, "deepseek-v4-flash", "session create model should include id")
assert_eq(session_payload.model.variant, "low", "session create model should include variant")

local lines = vim.fn.readfile(prompt_file)
local payload = vim.json.decode(lines[#lines])
local sent_text = payload.parts[1].text
assert_eq(payload.agent, "quick", "message payload should include configured opencode agent")
assert_eq(payload.model.providerID, "deepseek", "message payload model should include providerID")
assert_eq(payload.model.modelID, "deepseek-v4-flash", "message payload model should include modelID")
assert_eq(payload.variant, "low", "message payload should include configured variant")
assert_true(sent_text:match("@src/example.lua") ~= nil, "prompt should include queued context label")
assert_true(sent_text:match("function M.add") ~= nil, "prompt should include queued context code")
assert_true(sent_text:match("这是啥") ~= nil, "prompt should include input text")

assert_true(wait_for(function()
  local messages = ui.state().messages
  return messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("fake reply") ~= nil
end, 3000), "native UI should render assistant reply")
assert_eq(ui.input_text(), "", "input buffer should be cleared after submit")

local msg_state = ui.state()
local last_line = vim.api.nvim_buf_line_count(msg_state.message_buf)
assert_eq(vim.api.nvim_win_get_cursor(msg_state.message_win)[1], last_line, "message pane should auto-scroll to the bottom")
ui.focus_messages()
assert_eq(vim.api.nvim_get_current_win(), msg_state.message_win, "message pane should be focusable by keyboard")
assert_true(vim.api.nvim_get_mode().mode ~= "i", "message pane focus should stay out of insert mode")
ui.focus_input()
assert_eq(vim.api.nvim_get_current_win(), msg_state.input_win, "input pane should be focusable by keyboard")

opencode.show_models()
local model_lines = table.concat(vim.api.nvim_buf_get_lines(picker.state().buf, 0, -1, false), "\n")
assert_true(model_lines:match("deepseek") ~= nil, "model picker should group by provider")
assert_true(model_lines:match("deepseek%-v4%-flash") ~= nil, "model picker should include flash")
assert_true(model_lines:match("deepseek%-v4%-pro") ~= nil, "model picker should include pro")
opencode.toggle()
assert_true(picker.state().buf == nil, "hiding chat should close model picker")
opencode.toggle()
assert_true(opencode.select_model("deepseek", "deepseek-v4-pro"), "configured model should be selectable")
local selected_model = config.current_model()
assert_eq(selected_model.modelID, "deepseek-v4-pro", "select_model should update current model")
assert_eq(selected_model.variant, "high", "select_model should reset to model default variant")
opencode.show_variants()
local variant_lines = table.concat(vim.api.nvim_buf_get_lines(picker.state().buf, 0, -1, false), "\n")
assert_true(variant_lines:match("max") ~= nil, "variant picker should use current provider variants")
picker.close()
assert_true(opencode.select_variant("max"), "configured variant should be selectable")
assert_eq(config.current_model().variant, "max", "select_variant should update current variant")
assert_true(not opencode.select_model("deepseek", "missing-model"), "unconfigured model should be rejected")

opencode.ask("model switch")
assert_true(wait_for(function()
  local messages = ui.state().messages
  return messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("model switch") ~= nil
end, 3000), "request after model switch should complete")
lines = vim.fn.readfile(prompt_file)
payload = vim.json.decode(lines[#lines])
assert_eq(payload.model.providerID, "deepseek", "switched payload model should include providerID")
assert_eq(payload.model.modelID, "deepseek-v4-pro", "switched payload should use selected model")
assert_eq(payload.variant, "max", "switched payload should use selected variant")

opencode.ask("slow response")
assert_true(wait_for(function()
  return opencode._request.busy == true
end, 1000), "slow request should enter busy state")
opencode.ask("second request while busy")
assert_true(opencode._request.busy, "second request should not start while busy")
opencode.cancel()
assert_true(wait_for(function()
  local messages = ui.state().messages
  return opencode._request.busy == false and messages[#messages] and messages[#messages].role == "Cancelled" and messages[#messages].text == "Cancelled by opencode."
end, 2000), "cancel should abort backend and render cancellation")
assert_true(vim.fn.filereadable(tmp .. "/.opencode-chat-abort.jsonl") == 1, "cancel should call opencode session abort endpoint")
assert_eq(server.state().session_id, nil, "cancel should discard aborted session so the next request creates a fresh session")
local cancelled_count = 0
for _, message in ipairs(ui.state().messages) do
  if message.role == "Cancelled" then
    cancelled_count = cancelled_count + 1
  end
end
assert_eq(cancelled_count, 1, "single cancel should render exactly one Cancelled message")

local first_job = server.state().job_id
opencode.toggle()
opencode.toggle()
assert_true(server.state().job_id == first_job, "UI toggle should not restart headless server/session")

opencode.new_session()
assert_true(wait_for(function()
  return server.state().session_id == "test-session-2"
end, 3000), "new_session should create another session")
assert_eq(server.state().job_id, first_job, "new_session should not restart headless server")
local session_lines = vim.fn.readfile(session_file)
local newest_session_payload = vim.json.decode(session_lines[#session_lines])
assert_eq(newest_session_payload.model.id, "deepseek-v4-pro", "new_session should use selected model")
assert_eq(newest_session_payload.model.variant, "max", "new_session should use selected variant")
opencode.rename_session("Renamed test session")
assert_true(wait_for(function()
  return vim.fn.filereadable(tmp .. "/.opencode-chat-rename.jsonl") == 1 and server.state().sessions["test-session-2"] and server.state().sessions["test-session-2"].title == "Renamed test session"
end, 3000), "rename_session should update backend and local session cache")

opencode.show_sessions()
assert_true(wait_for(function()
  return picker.state().buf and vim.api.nvim_buf_is_valid(picker.state().buf)
end, 1000), "session picker should open")
local session_picker_lines = table.concat(vim.api.nvim_buf_get_lines(picker.state().buf, 0, -1, false), "\n")
assert_true(session_picker_lines:match("test%-session%-1") ~= nil, "session picker should include first session")
assert_true(session_picker_lines:match("Renamed test session") ~= nil, "session picker should include renamed latest session")
assert_true(session_picker_lines:match("foreign%-session") == nil, "session picker should filter out sessions from other projects")
picker.close()
opencode.select_session("test-session-1")
assert_true(wait_for(function()
  local messages = ui.state().messages
  return server.state().session_id == "test-session-1" and messages[#messages] and messages[#messages].text:match("model switch") ~= nil
end, 3000), "select_session should switch back and render history")

opencode.edit("make add subtract instead")
assert_true(wait_for(function()
  local messages = ui.state().messages
  return messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("a %- b") ~= nil
end, 5000), "edit should render backend edit summary")
assert_true(#vim.fn.readfile(session_file) >= 2, "cancel and explicit new session should create fresh sessions")
local updated = table.concat(vim.fn.readfile(file), "\n")
assert_true(updated:match("return a %- b") ~= nil, "backend edit should update sandbox file")

opencode.stop()
vim.fn.delete(tmp, "rf")
print("opencode-chat.nvim tests passed")
