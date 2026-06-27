if vim.g.loaded_opencode_chat == 1 then
  return
end

vim.g.loaded_opencode_chat = 1

require("opencode_chat").setup()
