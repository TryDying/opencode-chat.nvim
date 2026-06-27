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

local config = require("opencode_chat.config")
local root = require("opencode_chat.root")
local port = require("opencode_chat.port")
local client = require("opencode_chat.client")
local context = require("opencode_chat.context")
local opencode = require("opencode_chat")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/.git", "p")
vim.fn.mkdir(tmp .. "/src", "p")
local file = tmp .. "/src/example.lua"
vim.fn.writefile({ "one", "two", "three" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))

local fake_port = port.pick("127.0.0.1")
config.setup({
  command = cwd .. "/tests/fixtures/opencode",
  port = fake_port,
  startup_timeout_ms = 3000,
})
opencode.setup({
  command = cwd .. "/tests/fixtures/opencode",
  port = fake_port,
  startup_timeout_ms = 3000,
})

assert_true(vim.fn.exists(":OpencodeToggle") == 2, "plugin command should be loaded from plugin/opencode_chat.lua")
assert_eq(root.find(file), vim.fs.normalize(tmp), "root.find should detect .git root")
assert_eq(root.relative(file, tmp), "src/example.lua", "root.relative should produce project-relative path")

local file_ref, project_root = context.file_reference(0)
assert_eq(project_root, vim.fs.normalize(tmp), "file_reference should return project root")
assert_eq(file_ref, "@src/example.lua", "file_reference should use @relative/path")

vim.fn.setpos("'<", { 0, 3, 1, 0 })
vim.fn.setpos("'>", { 0, 1, 1, 0 })
assert_eq(context.selection_reference(0), "@src/example.lua#L1-L3", "selection_reference should sort reversed visual marks")

assert_eq(client.append_url({ host = "127.0.0.1", port = 12345 }), "http://127.0.0.1:12345/tui/append-prompt", "append URL should match opencode bridge")

opencode.append_file()

local append_file = tmp .. "/.opencode-chat-append.jsonl"
assert_true(wait_for(function()
  return vim.fn.filereadable(append_file) == 1
end, 5000), "append_file should reach fake /tui/append-prompt server")

local lines = vim.fn.readfile(append_file)
assert_true(#lines >= 1, "fake server should record at least one append payload")
local payload = vim.json.decode(lines[#lines])
assert_eq(payload.text, "@src/example.lua\n", "append payload should append current file reference without submitting")

local state = require("opencode_chat.terminal").state()
local first_job = state.job_id
opencode.toggle()
assert_true(state.job_id == first_job, "toggle hide should keep same job/session")
opencode.toggle()
assert_true(state.job_id == first_job, "toggle show should keep same job/session")

opencode.stop()
vim.fn.delete(tmp, "rf")
print("opencode-chat.nvim tests passed")
