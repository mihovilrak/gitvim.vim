--- Per-repository state and the event bus the UI subscribes to.
---
--- Keyed by worktree root from day one (D4). Nothing here touches the editor
--- API or git: it is a store plus a dispatcher, so the render layer can be
--- driven entirely from tests.

local repo_mod = require("gitvim.git.repo")

local M = {}

--- Things a store tracks staleness for.
---@alias gitvim.state.Slot "status"|"head"|"graph"|"timeline"

---@alias gitvim.state.Event
---| "status"   # a repo's status was replaced; payload { root, result }
---| "head"     # branch/upstream/ahead-behind changed; payload { root, branch }
---| "dirty"    # a slot was invalidated; payload { root, slot }
---| "graph"    # the GRAPH history or an expanded commit arrived; payload { root }
---| "error"    # a git call failed; payload { root, err }

---@class gitvim.state.Search
---@field pattern string
---@field replace string
---@field include string
---@field exclude string
---@field case boolean    match case
---@field word boolean    whole word
---@field regex boolean   treat the pattern as a regular expression

---@class gitvim.Store
---@field root string
---@field status? gitvim.status.Result
---@field collapsed table<string, boolean>  sidebar group collapse, per repo
---@field expanded table<string, boolean>   Files tab: expanded directories, per repo
---@field draft string                      unsent commit message, per repo
---@field graph_commit? string              commit requested by cross-navigation
---@field graph? gitvim.graph.State         GRAPH history, loaded by its section
---@field search gitvim.state.Search        Search tab form contents, per repo
---@field dirty table<gitvim.state.Slot, boolean>
local Store = {}
Store.__index = Store

---@type table<string, gitvim.Store>
local stores = {}

---@type table<gitvim.state.Event, table<integer, function>>
local subscribers = {}

--- Monotonic subscription ids, so unsubscribe is O(1) and never shifts a
--- neighbour out of a list being iterated.
local next_id = 0

--- Mark a slot stale. The refresh loop reads this to decide what to re-fetch.
---@param slot gitvim.state.Slot
function Store:mark_dirty(slot)
  self.dirty[slot] = true
  M.emit("dirty", { root = self.root, slot = slot })
end

---@param slot gitvim.state.Slot
---@return boolean
function Store:is_dirty(slot)
  return self.dirty[slot] == true
end

---@param slot gitvim.state.Slot
function Store:clear_dirty(slot)
  self.dirty[slot] = nil
end

--- Store a fresh status result and notify listeners.
---
--- Also pushes the branch header onto the repo, so `head` and `status` can
--- never disagree: they come from the same spawn.
---@param result gitvim.status.Result
function Store:set_status(result)
  self.status = result
  self:clear_dirty("status")
  self:clear_dirty("head")

  local repo = repo_mod.get(self.root)
  if repo then
    repo:set_branch(result.branch)
  end

  M.emit("head", { root = self.root, branch = result.branch })
  M.emit("status", { root = self.root, result = result })
end

--- Entries bucketed by group, or empty buckets before the first refresh.
---@return table<gitvim.status.Group, gitvim.status.Entry[]>
function Store:groups()
  if not self.status then
    return { merge = {}, staged = {}, changes = {}, untracked = {}, ignored = {} }
  end
  return require("gitvim.git.status").by_group(self.status)
end

---@param group string
---@return boolean
function Store:is_collapsed(group)
  return self.collapsed[group] == true
end

---@param group string
function Store:toggle_collapsed(group)
  self.collapsed[group] = not self.collapsed[group]
end

--- The store for a repo root, created on first use.
---@param root string
---@return gitvim.Store
function M.get(root)
  root = vim.fs.normalize(root)
  local store = stores[root]
  if not store then
    local search = require("gitvim.config").options.search
    store = setmetatable({
      root = root,
      collapsed = {},
      expanded = {},
      draft = "",
      search = {
        pattern = "",
        replace = "",
        include = search.include,
        exclude = search.exclude,
        case = search.case_sensitive,
        word = search.whole_word,
        regex = search.regex,
      },
      dirty = { status = true, head = true },
    }, Store)
    stores[root] = store
  end
  return store
end

---@return table<string, gitvim.Store>
function M.all()
  return stores
end

--- The store of the repository the sidebar is showing.
---@return gitvim.Store?
function M.active()
  local repo = repo_mod.active()
  return repo and M.get(repo.root) or nil
end

--- Listen for an event.
---@param event gitvim.state.Event
---@param fn fun(payload: table)
---@return fun() unsubscribe
function M.subscribe(event, fn)
  subscribers[event] = subscribers[event] or {}
  next_id = next_id + 1
  local id = next_id
  subscribers[event][id] = fn
  return function()
    if subscribers[event] then
      subscribers[event][id] = nil
    end
  end
end

--- Notify every listener of an event.
---
--- A throwing listener is reported and skipped rather than being allowed to
--- abort the rest of the fan-out: one broken tab must not freeze the sidebar.
---@param event gitvim.state.Event
---@param payload table
function M.emit(event, payload)
  local listeners = subscribers[event]
  if not listeners then
    return
  end
  for _, fn in pairs(listeners) do
    local ok, err = pcall(fn, payload)
    if not ok then
      vim.notify(("gitvim: %s listener failed: %s"):format(event, err), vim.log.levels.ERROR)
    end
  end
end

--- Mark every repo's slot stale, e.g. on FocusGained.
---@param slot gitvim.state.Slot
function M.mark_all_dirty(slot)
  for _, store in pairs(stores) do
    store:mark_dirty(slot)
  end
end

--- Drop all stores and listeners. Tests only.
function M.reset()
  stores = {}
  subscribers = {}
end

return M
