local M = {}

local uv = vim.uv or vim.loop

function M.pick(host)
  local tcp = assert(uv.new_tcp())
  assert(tcp:bind(host or "127.0.0.1", 0))
  local name = assert(tcp:getsockname())
  tcp:close()
  return name.port
end

return M
