--- Keep the sidebar in step with git operations it did not run itself.
---
--- Three triggers feed one debounced refresh of the active repository:
---   * `uv.fs_event` on the git directory (and `refs/heads`), which catches a
---     commit, checkout, stage or fetch made from a shell
---   * the configured autocmds (`BufWritePost`, `FocusGained` by default)
---   * explicit `request()` calls
---
--- While the sidebar is hidden nothing is spawned: the store is only marked
--- dirty, and opening the sidebar pays for one refresh instead.

local config = require("gitvim.config")

local M = {}

---@class gitvim.watcher.State
---@field timer? uv.uv_timer_t
---@field handles uv.uv_fs_event_t[]
---@field watching? string        gitdir the handles belong to
---@field group? integer
---@field unsubscribe? fun()
local W = { handles = {} }

--- Stop every fs_event handle.
local function unwatch()
  for _, handle in ipairs(W.handles) do
    if not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end
  W.handles = {}
  W.watching = nil
end

--- The refresh itself, once the debounce has settled.
local function fire()
  local repo = require("gitvim.git.repo").active()
  if not repo then
    return
  end
  if not require("gitvim.ui.sidebar").is_open() then
    require("gitvim.state").get(repo.root):mark_dirty("status")
    return
  end
  require("gitvim").refresh(repo.root, function(err)
    if err and err.kind ~= "not_a_repo" then
      vim.notify(require("gitvim.git.cli").format_error(err), vim.log.levels.ERROR)
    end
  end)
end

--- Ask for a refresh. Calls within `refresh.debounce` ms collapse into one.
function M.request()
  if not W.timer then
    W.timer = assert(vim.uv.new_timer())
  end
  W.timer:stop()
  W.timer:start(config.options.refresh.debounce, 0, vim.schedule_wrap(fire))
end

--- A file git rewrites on every operation, or a lock file coming and going.
--- Lock files are skipped: the rename that replaces them fires its own event.
---@param name? string
---@return boolean
local function relevant(name)
  return not (name and name:match("%.lock$"))
end

--- Point the fs_event handles at the active repository's git directory.
---
--- Idempotent, and cheap to call on every status event: it only does work
--- when the active repository has changed.
function M.watch()
  if not config.options.refresh.watch_gitdir then
    unwatch()
    return
  end
  local repo = require("gitvim.git.repo").active()
  local gitdir = repo and repo.gitdir
  if gitdir == W.watching then
    return
  end
  unwatch()
  if not gitdir then
    return
  end

  W.watching = gitdir
  for _, dir in ipairs({ gitdir, gitdir .. "/refs/heads" }) do
    if vim.uv.fs_stat(dir) then
      local handle = vim.uv.new_fs_event()
      if handle then
        local ok = handle:start(dir, {}, function(err, name)
          if not err and relevant(name) then
            M.request()
          end
        end)
        if ok then
          W.handles[#W.handles + 1] = handle
        else
          handle:close()
        end
      end
    end
  end
end

---@return string? gitdir  the directory being watched, if any
function M.watching()
  return W.watching
end

--- Install the autocmds and follow the active repository.
function M.setup()
  M.stop()
  W.group = vim.api.nvim_create_augroup("gitvim_watcher", { clear = true })

  local events = config.options.refresh.events
  if #events > 0 then
    vim.api.nvim_create_autocmd(events, {
      group = W.group,
      desc = "gitvim: refresh git status",
      callback = function()
        M.request()
      end,
    })
  end

  -- The active repository is only known after the first status read; every
  -- read after that may have switched it.
  W.unsubscribe = require("gitvim.state").subscribe("status", function()
    M.watch()
  end)
  M.watch()
end

--- Tear everything down. Also used by the specs between cases.
function M.stop()
  unwatch()
  if W.timer then
    W.timer:stop()
    if not W.timer:is_closing() then
      W.timer:close()
    end
    W.timer = nil
  end
  if W.group then
    pcall(vim.api.nvim_del_augroup_by_id, W.group)
    W.group = nil
  end
  if W.unsubscribe then
    W.unsubscribe()
    W.unsubscribe = nil
  end
end

return M
