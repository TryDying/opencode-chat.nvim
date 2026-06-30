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

  vim.api.nvim_create_user_command("OpencodeAppendContext", function()
    api.append_context()
  end, { range = true, force = true })

  vim.api.nvim_create_user_command("OpencodeContextRemove", function(opts)
    api.remove_context(opts.args)
  end, { nargs = 1, force = true })

  vim.api.nvim_create_user_command("OpencodeContextClear", function()
    api.clear_context()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeAsk", function(opts)
    api.ask(opts.args)
  end, { nargs = "*", force = true })

  vim.api.nvim_create_user_command("OpencodeEdit", function(opts)
    api.edit(opts.args)
  end, { nargs = "*", force = true })

  vim.api.nvim_create_user_command("OpencodeCancel", function()
    api.cancel()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeNewSession", function()
    api.new_session()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeSessions", function()
    api.show_sessions()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeRenameSession", function(opts)
    api.rename_session(opts.args)
  end, { nargs = "*", force = true })

  vim.api.nvim_create_user_command("OpencodeModels", function()
    api.show_models()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeVariants", function()
    api.show_variants()
  end, { force = true })

  vim.api.nvim_create_user_command("OpencodeStop", function()
    api.stop()
  end, { force = true })
end

return M
