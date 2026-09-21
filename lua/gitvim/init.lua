--- gitvim.nvim — a VS Code-shaped Git workbench for Neovim.
---
--- Entry point. See Plan.md for the architecture and the phase checklist.

local M = {}

M.version = "0.0.0-dev"

local did_setup = false
local detecting = false

--- Load status on the first open. The sidebar draws its empty/loading state
--- immediately; the status event redraws it when git finishes.
---@param path string
local function discover(path)
  if require("gitvim.git.repo").active() or detecting then
    return
  end
  detecting = true
  M.refresh(path, function(err)
    detecting = false
    if err and err.kind ~= "not_a_repo" then
      vim.notify(require("gitvim.git.cli").format_error(err), vim.log.levels.ERROR)
    end
  end)
end

---@return string
local function current_path()
  local path = vim.api.nvim_buf_get_name(0)
  return path ~= "" and path or (vim.uv.cwd() or ".")
end

---@param opts? gitvim.Config
function M.setup(opts)
  if did_setup then
    return
  end
  did_setup = true

  require("gitvim.config").setup(opts)
  require("gitvim.commands").setup()
  require("gitvim.ui.hl").setup()
  -- Later phases install the refresh watcher and buffer integrations.
end

--- Open (and focus) the sidebar.
---@param tab? gitvim.Tab
function M.open(tab)
  local path = current_path()
  require("gitvim.ui.sidebar").open(tab)
  discover(path)
end

--- Close the sidebar.
function M.close()
  require("gitvim.ui.sidebar").close()
end

--- Toggle the sidebar.
---@param tab? gitvim.Tab
function M.toggle(tab)
  local path = current_path()
  local sidebar = require("gitvim.ui.sidebar")
  sidebar.toggle(tab)
  if sidebar.is_open() then
    discover(path)
  end
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
    require("gitvim.git.repo").set_active(repo.root)
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
