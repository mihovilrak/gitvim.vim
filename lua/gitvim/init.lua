--- gitvim.nvim — a VS Code-shaped Git workbench for Neovim.
---
--- Entry point. See Plan.md for the architecture and the phase checklist.

local M = {}

M.version = "0.0.0-dev"

local did_setup = false

---@param opts? gitvim.Config
function M.setup(opts)
  if did_setup then
    return
  end
  did_setup = true

  require("gitvim.config").setup(opts)
  require("gitvim.commands").setup()
  -- Phase 2 onwards: ui.hl.setup(), buffer.signs.setup(), refresh watcher.
end

--- Open (and focus) the sidebar.
---@param tab? "scm"|"graph"|"timeline"
function M.open(tab)
  local _ = tab
  vim.notify("gitvim: sidebar not implemented yet (Plan.md phase 2)", vim.log.levels.WARN)
end

--- Close the sidebar.
function M.close() end

--- Toggle the sidebar.
function M.toggle()
  M.open()
end

---@return gitvim.Config
function M.config()
  return require("gitvim.config").options
end

return M
