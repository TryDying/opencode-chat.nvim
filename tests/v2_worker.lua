local repo, directory, result_file, stop_file = unpack(arg)
vim.opt.runtimepath:prepend(repo)
local server = require("opencode_chat.server")
require("opencode_chat").setup({ command = repo .. "/tests/fixtures/opencode", startup_timeout_ms = 3000 })
vim.cmd("cd " .. vim.fn.fnameescape(directory))
local finished, failure, response
server.send("independent Neovim", directory, {
  on_completed = function(text) response = text; finished = true end,
  on_error = function(err) failure = err; finished = true end,
})
local ok = vim.wait(5000, function() return finished end, 20)
assert(ok and not failure, tostring(failure or "worker request timed out"))
local state = server.state()
vim.fn.writefile({ vim.json.encode({ id = state.session_id, port = state.port, root = state.root, response = response }) }, result_file)
-- Parent stops another worker first, then asks survivors to send again.
local repeated = false
vim.wait(15000, function()
  if not repeated and vim.fn.filereadable(stop_file .. ".probe") == 1 then
    repeated = true
    server.send("survived other Neovim exit", directory, {
      on_completed = function(text) vim.fn.writefile({ text }, result_file .. ".probe") end,
      on_error = function(err) vim.fn.writefile({ "ERROR " .. err }, result_file .. ".probe") end,
    })
  end
  return vim.fn.filereadable(stop_file) == 1
end, 20)
server.stop()
