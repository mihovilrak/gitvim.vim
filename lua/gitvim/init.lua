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

--- Detect the repository for `path` and re-read its status into the store.
---
--- The foundation's one end-to-end path: repo -> status -> state -> events.
--- Everything the UI does later is a subscriber to what this emits.
---@param path? string   defaults to the current buffer
---@param cb? fun(err?: gitvim.git.Error, store?: gitvim.Store)
function M.refresh(path, cb)
  if type(path) == "function" then
    path, cb = nil, path
  end
  cb = cb or function() end

  require("gitvim.git.repo").detect(path, function(err, repo)
    if not repo then
      cb(err)
      return
    end
    local store = require("gitvim.state").get(repo.root)
    require("gitvim.git.status").get(repo.root, nil, function(serr, result)
      if serr then
        require("gitvim.state").emit("error", { root = repo.root, err = serr })
        cb(serr)
        return
      end
      store:set_status(result)
      cb(nil, store)
    end)
  end)
end

---@return gitvim.Config
function M.config()
  return require("gitvim.config").options
end

return M
