-- V2-specific protocol and multi-process regressions; invoked by tests/run.lua.
local repo = vim.fn.getcwd()
local client = require("opencode_chat.client")
local server = require("opencode_chat.server")
local chat = require("opencode_chat.chat")
local base = vim.fn.tempname()
vim.fn.mkdir(base .. "/a/.root", "p")
vim.fn.mkdir(base .. "/b/.root", "p")
vim.fn.mkdir(base .. "/c/.root", "p")
local workers = {}
local function wait(predicate, message)
  assert(vim.wait(6000, predicate, 20), message)
end
local function read(file) return vim.json.decode(vim.fn.readfile(file)[1]) end
local ok, err = xpcall(function()
  -- Different workspaces AND identical workspaces must remain independent.
  for index, workspace in ipairs({ "a", "b", "a", "a" }) do
    local worker = { result = base .. "/result" .. index, stop = base .. "/stop" .. index }
    worker.process = vim.system({ "nvim", "--headless", "-u", "NONE", "-l", repo .. "/tests/v2_worker.lua", repo, base .. "/" .. workspace, worker.result, worker.stop }, { text = true }, function(result) worker.exit = result end)
    table.insert(workers, worker)
  end
  for _, worker in ipairs(workers) do
    wait(function() return vim.fn.filereadable(worker.result) == 1 or worker.exit ~= nil end, "Neovim worker did not become ready")
    assert(vim.fn.filereadable(worker.result) == 1, "worker failed: " .. (worker.exit and worker.exit.stderr or ""))
  end
  local ids, ports = {}, {}
  for index, worker in ipairs(workers) do
    local result = read(worker.result)
    assert(not ids[result.id] and not ports[result.port], "Neovim instances must not share sessions or servers")
    ids[result.id], ports[result.port] = true, true
    assert(result.root == base .. (index == 2 and "/b" or "/a"), "wrong workspace location")
  end
  vim.fn.writefile({}, workers[1].stop)
  assert(workers[1].process:wait(4000).code == 0, "first worker failed to stop")
  for index = 2, #workers do
    local worker = workers[index]
    vim.fn.writefile({}, worker.stop .. ".probe")
    wait(function() return vim.fn.filereadable(worker.result .. ".probe") == 1 end, "survivor did not respond")
    assert(table.concat(vim.fn.readfile(worker.result .. ".probe"), ""):find("fake reply", 1, true), "exiting one Neovim affected another")
  end

  require("opencode_chat").setup({ command = repo .. "/tests/fixtures/opencode", startup_timeout_ms = 3000, response_timeout_ms = 5000 })
  vim.cmd("edit " .. vim.fn.fnameescape(base .. "/c/test.lua"))
  local started
  server.ensure_started(base .. "/c", function(success) started = success end)
  wait(function() return started end, "test server failed to start")
  local state = server.state()
  local opts = { host = "127.0.0.1", port = state.port, session_id = state.session_id, directory = state.root, model = { providerID = "deepseek", modelID = "deepseek-flash" } }
  local prompt_count = function()
    local file = base .. "/c/.opencode-chat-prompt.jsonl"
    return vim.fn.filereadable(file) == 1 and #vim.fn.readfile(file) or 0
  end
  -- Invalid model is surfaced, never silently replaced or submitted.
  local failure
  local bad = vim.tbl_extend("force", opts, { model = { providerID = "deepseek", modelID = "invalid-model" }, text = "must not submit" })
  chat.send(bad, { on_error = function(message) failure = message end })
  wait(function() return failure end, "invalid model should fail")
  assert(failure:find("400", 1, true) and prompt_count() == 0, "model configuration failure must stop admission")

  local function request(text)
    local completed, error_message, value
    local handle = chat.send(vim.tbl_extend("force", opts, { text = text }), {
      on_completed = function(full) value = full; completed = true end,
      on_error = function(message) error_message = message; completed = true end,
    })
    wait(function() return completed end, "V2 request timed out: " .. text)
    return value, error_message, handle
  end
  local value, message = request("disconnect recovery")
  assert(not message and value == "fake reply: disconnect recovery", "reconnection must recover missing text from history")
  assert(prompt_count() == 1, "SSE reconnect must not resubmit prompt")
  value, message = request("backend failure")
  assert(not value and message:find("fixture execution failed", 1, true), "execution failure must not become success")

  local cancelled, cancel_error
  local before = prompt_count()
  local handle = chat.send(vim.tbl_extend("force", opts, { text = "admission race slow response" }), {
    on_cancelled = function() cancelled = true end,
    on_error = function(error_message) cancel_error = error_message end,
  })
  wait(function() return prompt_count() > before end, "prompt was not admitted")
  handle.cancel()
  wait(function() return cancelled or cancel_error end, "in-flight admission cancellation hung")
  assert(cancelled and not cancel_error, "admission cancellation failed")
  local inbox_log = base .. "/c/.opencode-chat-inbox-cancel.jsonl"
  assert(vim.fn.filereadable(inbox_log) == 1, "cancel must remove admitted inbox item before interrupting")

  local rejected
  handle = chat.send(vim.tbl_extend("force", opts, { text = "cancel failure slow response" }), {
    on_cancelled = function() error("backend failure must not report cancelled") end,
    on_error = function(error_message) rejected = error_message end,
  })
  before = prompt_count()
  wait(function() return prompt_count() > before end, "cancel failure prompt was not admitted")
  handle.cancel()
  wait(function() return rejected end, "cancel failure should surface error")
  assert(rejected:find("500", 1, true), "HTTP cancellation failure was swallowed")

  -- Timeout uses the same inbox + interrupt cleanup, not just local EOF.
  local timed_out
  before = #vim.fn.readfile(inbox_log)
  chat.send(vim.tbl_extend("force", opts, { text = "slow response timeout", timeout_ms = 300 }), {
    on_error = function(error_message) timed_out = error_message end,
  })
  wait(function() return timed_out end, "timeout did not complete")
  assert(timed_out:find("timed out", 1, true), "timeout error was lost")
  assert(#vim.fn.readfile(inbox_log) > before, "timeout left an admitted inbox item behind")

  -- Externally-created history must fork; owned history can be resumed directly.
  local external
  client.create_session(state.root, opts, function(success, id) assert(success); external = id end)
  wait(function() return external end, "external session creation failed")
  local external_done
  chat.send(vim.tbl_extend("force", opts, { session_id = external, text = "external history" }), {
    on_completed = function() external_done = true end,
    on_error = function(error_message) error(error_message) end,
  })
  wait(function() return external_done end, "external history prompt failed")
  local selected
  server.select_session(external, function(success) selected = success end)
  wait(function() return selected end, "history fork failed")
  assert(state.session_id ~= external, "external history must not become a shared writable session")
  local fork = state.session_id
  selected = nil
  server.select_session(fork, function(success) selected = success end)
  wait(function() return selected end, "owned history resume failed")
  assert(state.session_id == fork, "owned session should not fork repeatedly")

  -- Late Quick creation must not replace a newly-opened Quick request.
  local quick = require("opencode_chat.quick")
  local quick_ui = require("opencode_chat.quick_ui")
  quick.ask("old quick request")
  quick.close()
  quick.ask("new quick request")
  wait(function()
    local messages = quick_ui.state().messages
    return not quick.state().busy and messages[#messages] and messages[#messages].text:find("fake reply: new quick request", 1, true)
  end, "late Quick callback overwrote reopened request")
  assert(server.state().session_id == fork, "Quick race changed main session")
  quick.close()

  -- Session creation callbacks capture their own location, not mutable state.root.
  local roots, copies = {}, {}
  for _, directory in ipairs({ base .. "/a", base .. "/b", base .. "/a" }) do
    server.ensure_started(directory, function(success, snapshot)
      assert(success)
      roots[directory] = snapshot
      table.insert(copies, { directory = directory, id = snapshot.session_id, root = snapshot.root })
    end)
  end
  wait(function() return #copies == 3 end, "concurrent location creation hung")
  assert(roots[base .. "/a"].session_id ~= roots[base .. "/b"].session_id, "locations shared session")
  for _, snapshot in ipairs(copies) do
    assert(snapshot.directory == snapshot.root, "late callback changed session location")
    assert(snapshot.id == roots[snapshot.directory].session_id, "same-location startup created duplicate sessions")
  end
end, debug.traceback)

server.stop()
for _, worker in ipairs(workers) do
  vim.fn.writefile({}, worker.stop)
  local result = worker.process:wait(3000)
  if result.code ~= 0 then pcall(worker.process.kill, worker.process, 9) end
end
vim.fn.delete(base, "rf")
assert(ok, err)
print("V2 protocol and concurrent Neovim tests passed")
