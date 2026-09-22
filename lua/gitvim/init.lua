--- gitvim.nvim — a VS Code-shaped Git workbench for Neovim.
---
--- Entry point. See Plan.md for the architecture and the phase checklist.

local M = {}

M.version = "0.1.0"

local did_setup = false
local detecting = false

--- Load status on the first open, and again on any open after the watcher
--- saw a change while the sidebar was hidden. The sidebar draws its
--- empty/loading state immediately; the status event redraws it when git
--- finishes.
---@param path string
local function discover(path)
  if detecting then
    return
  end
  local active = require("gitvim.git.repo").active()
  if active then
    if not require("gitvim.state").get(active.root):is_dirty("status") then
      return
    end
    path = active.root
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
  local buffer_opts = require("gitvim.config").options.buffer
  -- gitsigns is optional at runtime: the bridge makes these calls inert when
  -- it is missing, while :checkhealth still explains how to install it.
  require("gitvim.buffer.bridge").setup({
    current_line_blame = buffer_opts.blame,
    current_line_blame_formatter = buffer_opts.blame_format,
  })
  require("gitvim.buffer.signs").setup()
  require("gitvim.git.watcher").setup()
end

--- Whether `setup()` has run; for :checkhealth.
---@return boolean
function M._is_setup()
  return did_setup
end

--- Toggle current-line blame annotations.
---@param value? boolean
---@return boolean? enabled
function M.toggle_blame(value)
  return require("gitvim.buffer.blame").toggle(value)
end

--- Open the commit blamed for the current line in the Git graph.
function M.open_blame_commit()
  require("gitvim.buffer.blame").open_commit()
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

--- Open the two-pane review for one file (Plan.md Phase 6).
---@param root string
---@param path string  repository-relative
---@param opts? gitvim.review.Opts  `{ left_rev, right_rev, left_path }`
function M.review(root, path, opts)
  require("gitvim.ui.review").open(root, path, opts)
end

---@return gitvim.Config
function M.config()
  return require("gitvim.config").options
end

return M
