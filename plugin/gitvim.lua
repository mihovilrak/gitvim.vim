-- Lazy-safe entry point: registers :GitVim without loading the plugin proper.
if vim.g.loaded_gitvim then
  return
end
vim.g.loaded_gitvim = true

vim.api.nvim_create_user_command("GitVim", function(cmd)
  -- Replace this stub with the real command, then hand the parsed invocation
  -- over directly: re-running `:GitVim <args>` would lose quoting.
  vim.api.nvim_del_user_command("GitVim")
  require("gitvim").setup()
  require("gitvim.commands").dispatch(cmd)
end, {
  nargs = "*",
  desc = "gitvim (lazy stub)",
  complete = function(...)
    return require("gitvim.commands").complete(...)
  end,
})
