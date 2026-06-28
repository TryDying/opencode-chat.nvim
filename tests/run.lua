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
vim.fn.writefile({ "one", "two", "three" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))

local fake_port = port.pick("127.0.0.1")
opencode.setup({
  command = cwd .. "/tests/fixtures/opencode",
  port = fake_port,
  startup_timeout_ms = 3000,
})

assert_true(vim.fn.exists(":OpencodeToggle") == 2, "plugin command should be loaded")
assert_true(vim.fn.exists(":OpencodeAsk") == 2, "ask command should be registered")
assert_true(vim.fn.maparg("<M-->", "n") ~= "", "normal <M--> should be mapped")
assert_true(vim.fn.maparg("<M-->", "v") ~= "", "visual <M--> should be mapped")

assert_eq(root.find(file), vim.fs.normalize(tmp), "root.find should detect .git root")
assert_eq(root.relative(file, tmp), "src/example.lua", "root.relative should produce project-relative path")

local file_ref, project_root = context.file_reference(0)
assert_eq(project_root, vim.fs.normalize(tmp), "file_reference should return project root")
assert_eq(file_ref, "@src/example.lua", "file_reference should use @relative/path")

vim.fn.setpos("'<", { 0, 3, 1, 0 })
vim.fn.setpos("'>", { 0, 1, 1, 0 })
assert_eq(context.selection_reference(0), "@src/example.lua#L1-L3", "selection_reference should sort reversed visual marks")

vim.fn.setpos("'<", { 0, 0, 0, 0 })
vim.fn.setpos("'>", { 0, 0, 0, 0 })
vim.cmd("normal! ggVjj")
assert_eq(context.selection_reference(0), "@src/example.lua#L1-L3", "selection_reference should fall back to active visual positions")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)

assert_eq(client.session_url({ host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/api/session", "session URL should match headless API")
assert_eq(client.prompt_url("abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/api/session/abc/prompt", "prompt URL should match headless API")
assert_eq(client.messages_url("abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/session/abc/message", "messages URL should match headless API")
assert_eq(client.project_url({ host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/project", "project URL should match headless API")
assert_eq(client.project_messages_url("p", "abc", { host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/project/p/session/abc/message", "project messages URL should match headless API")
assert_eq(client.extract_assistant_text({
  { info = { role = "user" }, parts = { { type = "text", text = "question" } } },
  { info = { role = "assistant" }, parts = { { type = "text", text = "answer" } } },
}), "answer", "extract_assistant_text should ignore user echo and read assistant text parts")

opencode.append_file()
assert_eq(ui.state().context[1], "@src/example.lua", "append_file should add context to native UI draft")

opencode.ask("hello")

local prompt_file = tmp .. "/.opencode-chat-prompt.jsonl"
assert_true(wait_for(function()
  return vim.fn.filereadable(prompt_file) == 1 and server.state().session_id == "test-session" and server.state().project_id == "test-project"
end, 5000), "ask should create session and send prompt to fake headless server")

local lines = vim.fn.readfile(prompt_file)
local payload = vim.json.decode(lines[#lines])
assert_eq(payload.prompt.text, "@src/example.lua\n\nhello", "prompt should include queued context plus user text")

assert_true(wait_for(function()
  local messages = ui.state().messages
  return messages[#messages] and messages[#messages].role == "Assistant" and messages[#messages].text:match("fake reply") ~= nil
end, 3000), "native UI should render assistant reply")
assert_true(ui.state().messages[#ui.state().messages].text ~= payload.prompt.text, "assistant message must not render the echoed user prompt")

local first_job = server.state().job_id
opencode.toggle()
opencode.toggle()
assert_true(server.state().job_id == first_job, "UI toggle should not restart headless server/session")

opencode.stop()
vim.fn.delete(tmp, "rf")
print("opencode-chat.nvim tests passed")
