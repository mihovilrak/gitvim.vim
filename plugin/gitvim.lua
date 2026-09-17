-- Lazy-safe entry point: registers :GitVim without loading the plugin proper.
if vim.g.loaded_gitvim then
  return
end
vim.g.loaded_gitvim = true

vim.api.nvim_create_user_command("GitVim", function(cmd)
  -- Replace this stub with the real command on first use.
  vim.api.nvim_del_user_command("GitVim")
  require("gitvim").setup()
  vim.cmd(("GitVim %s"):format(cmd.args))
end, { nargs = "*", desc = "gitvim (lazy stub)" })
