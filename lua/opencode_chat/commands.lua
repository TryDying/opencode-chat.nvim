local M = {}

function M.setup(api)
  vim.api.nvim_create_user_command("OpencodeToggle", function()
    api.toggle()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeAppendFile", function()
    api.append_file()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeAppendSelection", function()
    api.append_selection()
  end, { range = true, force = true })

  vim.api.nvim_create_user_command("OpencodeAsk", function(opts)
    api.ask(opts.args)
  end, { nargs = "*", force = true })

  vim.api.nvim_create_user_command("OpencodeEdit", function(opts)
    api.edit(opts.args)
  end, { nargs = "*", force = true })

  vim.api.nvim_create_user_command("OpencodeApply", function()
    api.apply()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeReject", function()
    api.reject()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeNewSession", function()
    api.new_session()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeStop", function()
    api.stop()
  end, { force = true })
end

return M
