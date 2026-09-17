--- The :GitVim user command and its completion.

local M = {}

--- Subcommand name -> handler. Filled in as phases land.
---@type table<string, fun(args: string[])>
local subcommands = {
  open = function(args)
    require("gitvim").open(args[1])
  end,
  close = function()
    require("gitvim").close()
  end,
  toggle = function()
    require("gitvim").toggle()
  end,
}

function M.setup()
  vim.api.nvim_create_user_command("GitVim", function(cmd)
    local args = cmd.fargs
    local name = table.remove(args, 1) or "toggle"
    local handler = subcommands[name]
    if not handler then
      vim.notify("gitvim: unknown subcommand '" .. name .. "'", vim.log.levels.ERROR)
      return
    end
    handler(args)
  end, {
    nargs = "*",
    desc = "gitvim",
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return vim.startswith(name, lead)
      end, vim.tbl_keys(subcommands))
    end,
  })
end

return M
