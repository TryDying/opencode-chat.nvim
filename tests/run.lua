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
local context = require("opencode_chat.context")
local opencode = require("opencode_chat")
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
  agent = "build",
  model = "deepseek/deepseek-v4-flash",
  variant = "low",
})

assert_true(vim.fn.exists(":OpencodeToggle") == 2, "plugin command should be loaded")
assert_true(vim.fn.exists(":OpencodeAsk") == 2, "ask command should be registered")
assert_true(vim.fn.exists(":OpencodeEdit") == 2, "edit command should be registered")
assert_true(vim.fn.maparg("<M-->", "n") ~= "", "normal <M--> should be mapped")
assert_true(vim.fn.maparg("<M-->", "v") ~= "", "visual <M--> should be mapped")

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
assert_eq(client.extract_assistant_text({
  { info = { role = "user" }, parts = { { type = "text", text = "question" } } },
  { info = { role = "assistant" }, parts = { { type = "text", text = "answer" } } },
}), "answer", "extract_assistant_text should ignore user echo and read assistant text parts")

opencode.append_file()
assert_eq(ui.state().context[1].label, "@src/example.lua", "append_file should add structured context")
assert_true(ui.state().context[1].text:match("return a %+ b") ~= nil, "context should include code text")

ui.set_input("这是啥")
opencode.submit()

local prompt_file = tmp .. "/.opencode-chat-prompt.jsonl"
assert_true(wait_for(function()
  return vim.fn.filereadable(prompt_file) == 1 and server.state().session_id == "test-session"
end, 5000), "submit should create session and send prompt to fake headless server")

local lines = vim.fn.readfile(prompt_file)
local payload = vim.json.decode(lines[#lines])
local sent_text = payload.parts[1].text
assert_eq(payload.agent, "build", "payload should include configured opencode agent")
assert_eq(payload.model, "deepseek/deepseek-v4-flash", "payload should include configured model")
assert_eq(payload.variant, "low", "payload should include configured variant")
assert_true(sent_text:match("@src/example.lua") ~= nil, "prompt should include queued context label")
assert_true(sent_text:match("function M.add") ~= nil, "prompt should include queued context code")
assert_true(sent_text:match("这是啥") ~= nil, "prompt should include input text")

assert_true(wait_for(function()
  local messages = ui.state().messages
  return messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("fake reply") ~= nil
end, 3000), "native UI should render assistant reply")
assert_eq(ui.input_text(), "", "input buffer should be cleared after submit")

local first_job = server.state().job_id
opencode.toggle()
opencode.toggle()
assert_true(server.state().job_id == first_job, "UI toggle should not restart headless server/session")

opencode.edit("make add subtract instead")
assert_true(wait_for(function()
  local messages = ui.state().messages
  return messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("a %- b") ~= nil
end, 5000), "edit should render backend edit summary")
local updated = table.concat(vim.fn.readfile(file), "\n")
assert_true(updated:match("return a %- b") ~= nil, "backend edit should update sandbox file")

opencode.stop()
vim.fn.delete(tmp, "rf")
print("opencode-chat.nvim tests passed")
