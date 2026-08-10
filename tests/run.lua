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
local quick = require("opencode_chat.quick")
local quick_ui = require("opencode_chat.quick_ui")
local debug = require("opencode_chat.debug")

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
local setup_config = {
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
    append_context = "<leader>Xe",
    append_selection = "<M-->",
    sessions = "<leader>Xl",
    new_session = "<leader>Xn",
    models = "<leader>Xm",
    variants = "<leader>Xt",
    quick = "<leader>Xq",
    quick_context = "<leader>XQ",
  },
}
opencode.setup(setup_config)

local debug_log = tmp .. "/opencode-chat-debug.log"
vim.env.OPENCODE_CHAT_DEBUG_LOG = debug_log
debug.log("test", "debug_log_check", { ok = true })
vim.env.OPENCODE_CHAT_DEBUG_LOG = nil
assert_true(vim.fn.filereadable(debug_log) == 1 and table.concat(vim.fn.readfile(debug_log), "\n"):match("debug_log_check") ~= nil, "debug log should be controlled by OPENCODE_CHAT_DEBUG_LOG")

local quick_first_script = vim.fn.tempname() .. ".lua"
local quick_first_tmp = vim.fn.tempname()
local quick_first_port = port.pick("127.0.0.1")
vim.fn.writefile({
  "local repo = " .. vim.inspect(cwd),
  "local tmp = " .. vim.inspect(quick_first_tmp),
  "local port = " .. tostring(quick_first_port),
  "vim.opt.runtimepath:prepend(repo)",
  "package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path",
  "vim.cmd('runtime plugin/opencode_chat.lua')",
  "local function assert_true(value, message) if not value then error(message or 'expected truthy') end end",
  "local function wait_for(predicate, timeout_ms) local deadline = vim.loop.hrtime() + timeout_ms * 1000000; while vim.loop.hrtime() < deadline do if predicate() then return true end; vim.wait(50) end; return false end",
  "vim.fn.mkdir(tmp .. '/.git', 'p')",
  "vim.fn.mkdir(tmp .. '/src', 'p')",
  "local file = tmp .. '/src/quick-first.lua'",
  "vim.fn.writefile({ 'local value = 1', 'return value' }, file)",
  "vim.cmd('edit ' .. vim.fn.fnameescape(file))",
  "vim.bo.filetype = 'lua'",
  "local opencode = require('opencode_chat')",
  "local quick = require('opencode_chat.quick')",
  "local quick_ui = require('opencode_chat.quick_ui')",
  "local server = require('opencode_chat.server')",
  "opencode.setup({ command = repo .. '/tests/fixtures/opencode', port = port, startup_timeout_ms = 3000, response_timeout_ms = 3000, agent = 'quick', model = 'deepseek/deepseek-v4-flash', providers = { deepseek = { variants = { 'low', 'medium', 'high', 'max' }, models = { { id = 'deepseek-v4-flash', default_variant = 'low' } } } } })",
  "opencode.quick_append_context()",
  "assert_true(#quick_ui.state().context == 1, 'quick_context first should queue context')",
  "assert_true(vim.fn.maparg('<C-s>', 'i') ~= '', 'quick_context first should install input submit mapping')",
  "quick_ui.set_input('why is this syntax valid?')",
  "vim.api.nvim_set_current_win(quick_ui.state().input_win)",
  "vim.cmd('startinsert')",
  "vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-s>', true, false, true), 'xt', false)",
  "assert_true(wait_for(function() local messages = quick_ui.state().messages; return quick.state().busy == false and messages[#messages] and messages[#messages].role == 'Assistant' and messages[#messages].text:match('why is this syntax valid') ~= nil end, 5000), 'quick_context first should still allow asking')",
  "assert_true(server.state().session_id == nil, 'quick_context first should not create main chat session')",
  "opencode.quick_close()",
  "opencode.stop()",
}, quick_first_script)
local quick_first_result = vim.fn.system({ "nvim", "--headless", "-u", "NONE", "-l", quick_first_script })
local quick_first_code = vim.v.shell_error
vim.fn.delete(quick_first_script)
assert_eq(quick_first_code, 0, "quick_context should work before main chat UI is opened: " .. quick_first_result)

local server_exit_script = vim.fn.tempname() .. ".lua"
local server_exit_tmp = vim.fn.tempname()
local server_exit_port = port.pick("127.0.0.1")
local server_exit_cmd = vim.fn.tempname()
vim.fn.writefile({ "#!/usr/bin/env sh", "echo startup boom >&2", "exit 7" }, server_exit_cmd)
vim.fn.setfperm(server_exit_cmd, "rwx------")
vim.fn.writefile({
  "local repo = " .. vim.inspect(cwd),
  "local tmp = " .. vim.inspect(server_exit_tmp),
  "local port = " .. tostring(server_exit_port),
  "local command = " .. vim.inspect(server_exit_cmd),
  "vim.opt.runtimepath:prepend(repo)",
  "package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path",
  "vim.cmd('runtime plugin/opencode_chat.lua')",
  "local function assert_true(value, message) if not value then error(message or 'expected truthy') end end",
  "local function wait_for(predicate, timeout_ms) local deadline = vim.loop.hrtime() + timeout_ms * 1000000; while vim.loop.hrtime() < deadline do if predicate() then return true end; vim.wait(50) end; return false end",
  "vim.fn.mkdir(tmp .. '/.git', 'p')",
  "vim.fn.mkdir(tmp .. '/src', 'p')",
  "local file = tmp .. '/src/server-exit.lua'",
  "vim.fn.writefile({ 'return 1' }, file)",
  "vim.cmd('edit ' .. vim.fn.fnameescape(file))",
  "local opencode = require('opencode_chat')",
  "local quick = require('opencode_chat.quick')",
  "local quick_ui = require('opencode_chat.quick_ui')",
  "opencode.setup({ command = command, port = port, startup_timeout_ms = 800, response_timeout_ms = 800, agent = 'quick', model = 'deepseek/deepseek-v4-flash', providers = { deepseek = { variants = { 'low' }, models = { { id = 'deepseek-v4-flash', default_variant = 'low' } } } } })",
  "opencode.quick('hello')",
  "assert_true(wait_for(function() local messages = quick_ui.state().messages; local last = messages[#messages]; return quick.state().busy == false and last and last.role == 'Error' and last.text:match('exited before becoming ready') ~= nil and last.text:match('startup boom') ~= nil and last.text:match('exit_code=7') ~= nil end, 3000), 'server exit before ready should surface stderr and exit code instead of staying Thinking')",
  "opencode.quick_close()",
}, server_exit_script)
local server_exit_result = vim.fn.system({ "nvim", "--headless", "-u", "NONE", "-l", server_exit_script })
local server_exit_code = vim.v.shell_error
vim.fn.delete(server_exit_script)
vim.fn.delete(server_exit_cmd)
assert_eq(server_exit_code, 0, "server exit before ready should not leave quick ask thinking: " .. server_exit_result)

assert_true(vim.fn.exists(":OpencodeToggle") == 2, "plugin command should be loaded")
assert_true(vim.fn.exists(":OpencodeAppendContext") == 2, "append context command should be registered")
assert_true(vim.fn.exists(":OpencodeContextRemove") == 2, "context remove command should be registered")
assert_true(vim.fn.exists(":OpencodeContextClear") == 2, "context clear command should be registered")
assert_true(vim.fn.exists(":OpencodeAsk") == 2, "ask command should be registered")
assert_true(vim.fn.exists(":OpencodeQuick") == 2, "quick command should be registered")
assert_true(vim.fn.exists(":OpencodeQuickClose") == 2, "quick close command should be registered")
assert_true(vim.fn.exists(":OpencodeQuickCancel") == 2, "quick cancel command should be registered")
assert_true(vim.fn.exists(":OpencodeQuickAppendContext") == 2, "quick context command should be registered")
assert_true(vim.fn.exists(":OpencodeEdit") == 2, "edit command should be registered")
assert_true(vim.fn.exists(":OpencodeCancel") == 2, "cancel command should be registered")
assert_true(vim.fn.exists(":OpencodeSessions") == 2, "sessions command should be registered")
assert_true(vim.fn.exists(":OpencodeRenameSession") == 2, "rename session command should be registered")
assert_true(vim.fn.exists(":OpencodeDeleteSession") == 2, "delete session command should be registered")
assert_true(vim.fn.exists(":OpencodeModels") == 2, "models command should be registered")
assert_true(vim.fn.exists(":OpencodeVariants") == 2, "variants command should be registered")
assert_true(vim.fn.maparg("<M-->", "n") ~= "", "normal <M--> should be mapped")
assert_true(vim.fn.maparg("<M-->", "i") ~= "", "insert <M--> should be mapped for toggle")
assert_true(vim.fn.maparg("<M-->", "v") ~= "", "visual <M--> should be mapped")
assert_true(vim.fn.maparg("<leader>Xe", "n") ~= "", "normal append context keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xe", "v") ~= "", "visual append context keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xl", "n") ~= "", "session list keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xn", "n") ~= "", "new session keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xr", "n") == "", "rename session keymap should not be mapped by recommended test config")
assert_true(vim.fn.maparg("<leader>Xm", "n") ~= "", "model picker keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xt", "n") ~= "", "variant picker keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xq", "n") ~= "", "quick ask keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xq", "i") == "", "quick ask leader keymap should not be mapped in insert mode")
assert_true(vim.fn.maparg("<leader>XQ", "n") ~= "", "normal quick context keymap should be mapped")
assert_true(vim.fn.maparg("<leader>XQ", "v") ~= "", "visual quick context keymap should be mapped")
assert_true(vim.fn.maparg("<leader>Xv", "n") == "", "old variant keymap should not be mapped")
assert_true(not pcall(function()
  config.setup({ variant = "low" })
end), "top-level variant config should be rejected")
assert_eq(config.current_model().modelID, "deepseek-v4-flash", "failed config setup should preserve current config")
config.setup({
  model = "opencode-go/qwen3-coder",
  providers = {
    {
      id = "opencode-go",
      variants = { "low", "medium" },
      models = {
        { id = "qwen3-coder", default_variant = "medium" },
      },
    },
  },
})
assert_eq(config.current_model().providerID, "opencode-go", "array-style provider config should support hyphenated IDs")
assert_eq(config.current_model().modelID, "qwen3-coder", "array-style provider config should select its model")
assert_eq(config.current_model().variant, "medium", "array-style provider config should use model default variant")
config.setup(setup_config)

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

vim.fn.setpos("'<", { 0, 3, 1, 0 })
vim.fn.setpos("'>", { 0, 5, 1, 0 })
vim.cmd("normal! 8G0V")
assert_eq(context.selection_item(0).label, "@src/example.lua#L8-L8", "active visual selection should take precedence over stale visual marks")
vim.cmd("normal! \027")

vim.fn.setpos("'<", { 0, 0, 0, 0 })
vim.fn.setpos("'>", { 0, 0, 0, 0 })
vim.cmd("normal! ggVjj")
assert_eq(context.selection_item(0).label, "@src/example.lua#L1-L3", "selection_item should fall back to active visual positions")
opencode.append_selection()
assert_eq(ui.state().context[#ui.state().context].label, "@src/example.lua#L1-L3", "visual append should queue the active selection")
assert_eq(vim.api.nvim_get_current_win(), ui.state().input_win, "visual append should focus opencode input")
assert_true(vim.api.nvim_get_mode().mode ~= "v" and vim.api.nvim_get_mode().mode ~= "V", "visual append should leave visual mode")
assert_eq(root.find(), vim.fs.normalize(tmp), "root.find should ignore chat buffers and use visible project files")
ui.consume_context()
vim.cmd("normal! \027")

local code_win = nil
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == file then
    code_win = win
    break
  end
end
assert_true(code_win and vim.api.nvim_win_is_valid(code_win), "code pane should remain open")
vim.api.nvim_set_current_win(code_win)
opencode.append_context()
assert_eq(vim.api.nvim_get_current_win(), code_win, "normal append_context should keep focus on code pane")
assert_eq(#ui.state().context, 1, "normal append_context should add current file once")
assert_eq(ui.state().context[1].label, "@src/example.lua", "normal append_context should add current file")
opencode.append_context()
assert_eq(#ui.state().context, 1, "append_context should deduplicate current file")

vim.api.nvim_set_current_win(code_win)
vim.cmd("normal! 8G0V")
opencode.append_context()
assert_eq(vim.api.nvim_get_current_win(), code_win, "visual append_context should keep focus on code pane")
assert_true(vim.api.nvim_get_mode().mode ~= "v" and vim.api.nvim_get_mode().mode ~= "V", "visual append_context should leave visual mode")
assert_eq(#ui.state().context, 2, "visual append_context should add a second unique context")
assert_eq(ui.state().context[2].label, "@src/example.lua#L8-L8", "visual append_context should add selected lines")
vim.api.nvim_set_current_win(ui.state().message_win)
vim.api.nvim_win_set_cursor(ui.state().message_win, { 4, 0 })
assert_true(opencode.remove_context_at_cursor(), "context line d action should remove item under cursor")
assert_eq(#ui.state().context, 1, "remove_context_at_cursor should remove one context item")
opencode.clear_context()
assert_eq(#ui.state().context, 0, "clear_context should remove all context items")
vim.api.nvim_set_current_win(code_win)

assert_eq(client.session_url({ host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/session", "session URL should target current API")
assert_eq(client.message_url("abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/session/abc/message", "message URL should target current API")
assert_eq(client.prompt_async_url("abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/session/abc/prompt_async", "async prompt URL should target current API")
assert_eq(client.abort_url("abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/session/abc/abort", "abort URL should target session abort API")
assert_eq(client.rename_session_url("abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/session/abc", "rename URL should target session update API")
assert_eq(client.delete_session_url("abc", { host = "127.0.0.1", port = 12345, directory = "/tmp/a b" }), "http://127.0.0.1:12345/session/abc?directory=%2Ftmp%2Fa%20b", "delete URL should include encoded directory query")
assert_eq(client.current_project_url({ host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/project/current", "current project URL should target project/current API")
assert_eq(client.format_error({ status = 400, body = "bad request", stderr = "" }, "fallback"), "HTTP 400: bad request", "format_error should not let empty stderr hide HTTP body")

opencode.append_file()
assert_eq(ui.state().context[1].label, "@src/example.lua", "append_file should add structured context")
assert_true(ui.state().context[1].text:match("return a %+ b") ~= nil, "context should include code text")
assert_true(vim.api.nvim_win_is_valid(ui.state().status_win), "status window should exist")
assert_eq(vim.api.nvim_win_get_config(ui.state().message_win).relative, "", "chat message pane should be a normal split, not a float")
assert_eq(vim.api.nvim_buf_get_name(ui.state().message_buf), "opencode-chat://messages", "message pane should have a stable buffer name")
assert_eq(vim.api.nvim_buf_get_name(ui.state().input_buf), "opencode-chat://input", "input pane should have a stable buffer name")
assert_eq(vim.api.nvim_buf_get_name(ui.state().status_buf), "opencode-chat://status", "status pane should have a stable buffer name")
assert_true(vim.api.nvim_win_get_width(ui.state().message_win) <= math.ceil(vim.o.columns * 0.45), "chat panel should use the right-side configured width")
assert_true(ui.state().toolbar_win == nil, "toolbar window should be removed")
assert_true(vim.api.nvim_win_get_position(ui.state().status_win)[1] > vim.api.nvim_win_get_position(ui.state().input_win)[1], "status bar should be below input pane")
assert_eq(vim.wo[ui.state().message_win].winbar, "", "message pane should not reserve a blank winbar line")
assert_eq(vim.wo[ui.state().input_win].winbar, "", "input pane should not reserve a blank winbar line")
assert_eq(vim.wo[ui.state().status_win].winbar, "", "status pane should not reserve a blank winbar line")
assert_eq(config.get().ui.width, 0.4, "chat panel width should be configurable")
assert_eq(config.get().ui.height, 1.0, "chat panel height should be configurable")
assert_eq(config.get().ui.message_height, nil, "message pane height should be optionally configurable")

ui.set_input("这是啥")
opencode.submit()

local prompt_file = tmp .. "/.opencode-chat-prompt.jsonl"
local session_file = tmp .. "/.opencode-chat-session.jsonl"
assert_true(wait_for(function()
  local messages = ui.state().messages
  local last = messages[#messages]
  return opencode._request.busy == false and last and last.role == "Assistant" and last.text:match("fake reply") ~= nil
end, 5000), "assistant reply should render from the message response")
assert_true(wait_for(function()
  return vim.fn.filereadable(prompt_file) == 1 and vim.fn.filereadable(session_file) == 1 and server.state().session_id == "test-session-1"
end, 5000), "submit should create session and send prompt to fake headless server")
assert_true(type(server.state().job_pid) == "number" and server.state().job_pid > 0, "server state should record the OS process id")
assert_true(vim.fn.filereadable(tmp .. "/.opencode-chat-events.jsonl") == 1, "message sending should open SSE event subscriptions")

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
  return opencode._request.busy == false and messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("fake reply") ~= nil
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

local function tab_has_chat(tab)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if ui.is_chat_window(win) then
      return true
    end
  end
  return false
end

local mirror_tab1 = vim.api.nvim_get_current_tabpage()
local mirror_tab1_input = ui.state().input_win
local mirror_file = tmp .. "/src/mirror.lua"
vim.fn.writefile({ "return 'mirror'" }, mirror_file)
ui.add_message("System", "mirror check")
vim.cmd("tabnew " .. vim.fn.fnameescape(mirror_file))
local mirror_tab2 = vim.api.nvim_get_current_tabpage()
assert_true(wait_for(function()
  return tab_has_chat(mirror_tab2)
end, 1000), "new tab should automatically show chat mirror while chat is globally visible")
assert_true(tab_has_chat(mirror_tab1), "tab1 should keep its chat mirror")
assert_true(tab_has_chat(mirror_tab2), "tab2 should open a chat mirror")
assert_true(table.concat(vim.api.nvim_buf_get_lines(ui.state().message_buf, 0, -1, false), "\n"):match("mirror check") ~= nil, "chat mirrors should share messages")
ui.set_input("mirrored draft")
vim.api.nvim_set_current_tabpage(mirror_tab1)
assert_eq(ui.input_text(), "mirrored draft", "chat mirrors should share input draft")
vim.api.nvim_set_current_win(mirror_tab1_input)
opencode.toggle()
assert_true(not tab_has_chat(mirror_tab1), "toggle hide should close chat mirror in tab1")
assert_true(not tab_has_chat(mirror_tab2), "toggle hide should close chat mirror in tab2")
vim.api.nvim_set_current_tabpage(mirror_tab2)
vim.cmd("tabclose")
vim.api.nvim_set_current_tabpage(mirror_tab1)
opencode.toggle()
local grouped_panes = vim.deepcopy({
  message_win = ui.state().message_win,
  input_win = ui.state().input_win,
  status_win = ui.state().status_win,
})
vim.api.nvim_set_current_win(grouped_panes.message_win)
vim.cmd("quit")
assert_true(wait_for(function()
  return not vim.api.nvim_win_is_valid(grouped_panes.message_win)
    and not vim.api.nvim_win_is_valid(grouped_panes.input_win)
    and not vim.api.nvim_win_is_valid(grouped_panes.status_win)
    and not tab_has_chat(mirror_tab1)
end, 1000), "closing one chat pane should close the sibling panes in the same tab")
opencode.toggle()
ui.set_input("")

local original_tab = vim.api.nvim_get_current_tabpage()
local original_tab_count = #vim.api.nvim_list_tabpages()
ui.hide()
vim.cmd("tabnew " .. vim.fn.fnameescape(file))
opencode.toggle()
assert_true(vim.api.nvim_win_is_valid(ui.state().message_win), "chat should open in isolated tab for autoclose test")
local code_win_for_autoclose = nil
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == file then
    code_win_for_autoclose = win
    break
  end
end
assert_true(code_win_for_autoclose and vim.api.nvim_win_is_valid(code_win_for_autoclose), "autoclose test should find code window")
vim.api.nvim_set_current_win(code_win_for_autoclose)
vim.cmd("close")
assert_true(wait_for(function()
  return vim.api.nvim_get_current_tabpage() == original_tab
    and #vim.api.nvim_list_tabpages() == original_tab_count
    and not vim.api.nvim_win_is_valid(ui.state().message_win or -1)
    and not vim.api.nvim_win_is_valid(ui.state().input_win or -1)
    and not vim.api.nvim_win_is_valid(ui.state().status_win or -1)
end, 1000), "tab should close automatically when only chat panes remain and another tab exists")
opencode.toggle()

local quit_script = vim.fn.tempname() .. ".lua"
local quit_file = tmp .. "/src/quit-last-tab.lua"
vim.fn.writefile({
  "local repo = " .. vim.inspect(cwd),
  "local file = " .. vim.inspect(quit_file),
  "vim.opt.runtimepath:prepend(repo)",
  "package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path",
  "vim.cmd('runtime plugin/opencode_chat.lua')",
  "require('opencode_chat').setup({})",
  "vim.cmd('edit ' .. vim.fn.fnameescape(file))",
  "require('opencode_chat').toggle()",
  "local ui = require('opencode_chat.ui')",
  "for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do",
  "  if not ui.is_chat_window(win) then vim.api.nvim_set_current_win(win); break end",
  "end",
  "vim.defer_fn(function() pcall(vim.cmd, 'cquit 7') end, 1000)",
  "vim.cmd('close')",
  "vim.wait(2000)",
}, quit_script)
local quit_result = vim.fn.system({ "nvim", "--headless", "-u", "NONE", "-l", quit_script })
assert_eq(vim.v.shell_error, 0, "last-tab chat cleanup should let Neovim quit instead of leaving a blank buffer: " .. quit_result)
vim.fn.delete(quit_script)

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
  return opencode._request.busy == false and messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("model switch") ~= nil
end, 3000), "request after model switch should complete")
lines = vim.fn.readfile(prompt_file)
payload = vim.json.decode(lines[#lines])
assert_eq(payload.model.providerID, "deepseek", "switched payload model should include providerID")
assert_eq(payload.model.modelID, "deepseek-v4-pro", "switched payload should use selected model")
assert_eq(payload.variant, "max", "switched payload should use selected variant")

opencode.ask("partial response")
assert_true(wait_for(function()
  local messages = ui.state().messages
  return opencode._request.busy == false and messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("partial response") ~= nil
end, 3000), "async polling should wait for the completed assistant response instead of returning an in-progress partial")
assert_true(ui.state().messages[#ui.state().messages].text:match("fake reply: partial$") == nil, "async polling should not render the unfinished partial assistant text")

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
local edit_win = vim.fn.win_getid(vim.fn.winnr("#"))
if edit_win == 0 or not vim.api.nvim_win_is_valid(edit_win) or edit_win == ui.state().input_win then
  edit_win = vim.api.nvim_list_wins()[1]
end
if edit_win and vim.api.nvim_win_is_valid(edit_win) and edit_win ~= ui.state().input_win and edit_win ~= ui.state().message_win then
  vim.api.nvim_set_current_win(edit_win)
  opencode.toggle()
  assert_eq(vim.api.nvim_get_current_win(), ui.state().input_win, "toggle should refocus opencode chat when panel is visible but unfocused")
end
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
assert_true(session_picker_lines:match("subagent%-session") == nil, "session picker should hide subagent sessions")
assert_true(session_picker_lines:match("@runner subagent") == nil, "session picker should hide subagent titles")

local function picker_line_matching(pattern)
  for line, text in ipairs(vim.api.nvim_buf_get_lines(picker.state().buf, 0, -1, false)) do
    if text:match(pattern) then
      return line
    end
  end
end

local original_input = vim.ui.input
vim.ui.input = function(opts, cb)
  if (opts.prompt or ""):match("Session title") then
    cb("Picker renamed session")
  elseif (opts.prompt or ""):match("Delete session") then
    cb("y")
  else
    original_input(opts, cb)
  end
end

vim.api.nvim_set_current_win(picker.state().win)
vim.api.nvim_win_set_cursor(picker.state().win, { assert(picker_line_matching("Renamed test session"), "renamed session line should exist"), 0 })
picker.run_action("r")
assert_true(wait_for(function()
  return server.state().sessions["test-session-2"] and server.state().sessions["test-session-2"].title == "Picker renamed session"
end, 3000), "session picker r action should rename selected session")

assert_true(wait_for(function()
  return picker.state().buf and vim.api.nvim_buf_is_valid(picker.state().buf) and picker_line_matching("Picker renamed session") ~= nil
end, 1000), "session picker should refresh after rename")
vim.api.nvim_set_current_win(picker.state().win)
vim.api.nvim_win_set_cursor(picker.state().win, { assert(picker_line_matching("Picker renamed session"), "deletable session line should exist"), 0 })
picker.run_action("d")
assert_true(wait_for(function()
  return vim.fn.filereadable(tmp .. "/.opencode-chat-delete.jsonl") == 1 and server.state().sessions["test-session-2"] == nil
end, 3000), "session picker d action should delete selected session after confirmation")
assert_true(wait_for(function()
  return picker.state().buf and vim.api.nvim_buf_is_valid(picker.state().buf) and picker_line_matching("Picker renamed session") == nil
end, 1000), "session picker should refresh after delete")
vim.ui.input = original_input
picker.close()
opencode.select_session("test-session-1")
assert_true(wait_for(function()
  local messages = ui.state().messages
  return server.state().session_id == "test-session-1" and messages[#messages] and messages[#messages].text:match("partial response") ~= nil
end, 3000), "select_session should switch back and render history")

local main_session_before_quick = server.state().session_id
opencode.append_file()
assert_eq(#ui.state().context, 1, "main context should remain queued before quick ask")
vim.api.nvim_set_current_win(code_win)
vim.cmd("normal! 8G0V")
opencode.quick_append_context()
assert_true(vim.api.nvim_get_mode().mode ~= "v" and vim.api.nvim_get_mode().mode ~= "V", "visual quick_append_context should leave visual mode")
assert_eq(quick_ui.state().context[#quick_ui.state().context].label, "@src/example.lua#L8-L8", "visual quick_append_context should queue selected lines")
opencode.quick_clear_context()
opencode.quick_close()
vim.api.nvim_set_current_win(code_win)
opencode.quick("quick branch")
assert_true(wait_for(function()
  local messages = quick_ui.state().messages
  return quick.state().busy == false and messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("quick branch") ~= nil
end, 3000), "quick ask should render assistant reply")
assert_eq(vim.api.nvim_win_get_config(quick_ui.state().message_win).relative, "editor", "quick ask should use a floating message window")
assert_eq(server.state().session_id, main_session_before_quick, "quick ask should not replace the main chat session")
assert_eq(#ui.state().context, 1, "quick ask should not consume main chat context")
lines = vim.fn.readfile(prompt_file)
payload = vim.json.decode(lines[#lines])
sent_text = payload.parts[1].text
assert_true(sent_text:match("quick branch") ~= nil, "quick prompt should include question")
assert_true(sent_text:match("@src/example.lua") == nil, "quick prompt should not consume main queued context")
assert_eq(payload.model.modelID, "deepseek-v4-pro", "quick message should reuse selected model")
assert_eq(payload.variant, "max", "quick message should reuse selected variant")
local quick_session_id = quick.state().session.session_id
local quick_session_count = #vim.fn.readfile(session_file)
opencode.quick_append_file()
assert_eq(#quick_ui.state().context, 1, "quick context should be isolated")
opencode.quick("quick follow")
assert_true(wait_for(function()
  local messages = quick_ui.state().messages
  return quick.state().busy == false and messages[#messages] and messages[#messages].text:match("quick follow") ~= nil
end, 3000), "quick ask should support multiple turns")
assert_eq(quick.state().session.session_id, quick_session_id, "quick ask should reuse its temporary session while open")
assert_eq(#vim.fn.readfile(session_file), quick_session_count, "quick multi-turn should not create another session")
lines = vim.fn.readfile(prompt_file)
payload = vim.json.decode(lines[#lines])
assert_true(payload.parts[1].text:match("@src/example.lua") ~= nil, "quick prompt should include quick-only context")
local quick_panes = vim.deepcopy({
  message_win = quick_ui.state().message_win,
  input_win = quick_ui.state().input_win,
  status_win = quick_ui.state().status_win,
})
vim.api.nvim_set_current_win(quick_panes.input_win)
local insert_q_map = vim.fn.maparg("q", "i", false, true)
assert_true(type(insert_q_map) ~= "table" or insert_q_map.buffer ~= 1, "q should not be mapped in quick input insert mode")
assert_true(vim.api.nvim_win_is_valid(quick_panes.input_win), "typing q in quick input insert mode should not close quick panes")
quick_ui.clear_input()
vim.api.nvim_feedkeys("q", "xt", false)
assert_true(wait_for(function()
  if quick.state().session ~= nil then
    return false
  end
  if vim.fn.filereadable(tmp .. "/.opencode-chat-delete.jsonl") ~= 1 then
    return false
  end
  local delete_lines = table.concat(vim.fn.readfile(tmp .. "/.opencode-chat-delete.jsonl"), "\n")
  return delete_lines:find(quick_session_id, 1, true) ~= nil
end, 3000), "pressing q in quick input normal mode should delete the temporary backend session")
assert_true(not vim.api.nvim_win_is_valid(quick_panes.message_win) and not vim.api.nvim_win_is_valid(quick_panes.input_win) and not vim.api.nvim_win_is_valid(quick_panes.status_win), "pressing q in quick input normal mode should close all quick panes")
assert_true(not vim.api.nvim_buf_is_valid(quick_ui.state().message_buf or -1), "quick close should delete quick buffers")
opencode.clear_context()

opencode.quick("slow response")
assert_true(wait_for(function()
  return quick.state().busy == true and quick.state().session ~= nil
end, 1000), "slow quick ask should enter busy state")
local cancelled_quick_session = quick.state().session.session_id
opencode.quick_cancel()
assert_true(wait_for(function()
  local messages = quick_ui.state().messages
  return quick.state().busy == false and messages[#messages] and messages[#messages].role == "Cancelled"
end, 3000), "quick cancel should abort and render cancellation")
assert_true(wait_for(function()
  local abort_lines = vim.fn.filereadable(tmp .. "/.opencode-chat-abort.jsonl") == 1 and table.concat(vim.fn.readfile(tmp .. "/.opencode-chat-abort.jsonl"), "\n") or ""
  local delete_lines = vim.fn.filereadable(tmp .. "/.opencode-chat-delete.jsonl") == 1 and table.concat(vim.fn.readfile(tmp .. "/.opencode-chat-delete.jsonl"), "\n") or ""
  return abort_lines:find(cancelled_quick_session, 1, true) ~= nil and delete_lines:find(cancelled_quick_session, 1, true) ~= nil
end, 3000), "quick cancel should abort and delete the temporary session")
opencode.quick_close()

opencode.edit("make add subtract instead")
assert_true(wait_for(function()
  local messages = ui.state().messages
  return messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("a %- b") ~= nil
end, 5000), "edit should render backend edit summary")
assert_true(#vim.fn.readfile(session_file) >= 2, "cancel and explicit new session should create fresh sessions")
local updated = table.concat(vim.fn.readfile(file), "\n")
assert_true(updated:match("return a %- b") ~= nil, "backend edit should update sandbox file")

local final_job = server.state().job_id
opencode.stop()
if final_job then
  assert_true(vim.fn.jobwait({ final_job }, 0)[1] ~= -1, "opencode.stop should wait for the fake server job to exit")
end
vim.fn.delete(tmp, "rf")
print("opencode-chat.nvim tests passed")
