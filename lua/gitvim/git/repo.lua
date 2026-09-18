--- Repository identity and the repo registry.
---
--- Per D4 every repository is keyed by its worktree root from day one, so the
--- post-MVP multi-repo work is a fan-out over this registry rather than a
--- rewrite of a global singleton.

local cli = require("gitvim.git.cli")
local status = require("gitvim.git.status")

local M = {}

---@class gitvim.Repo
---@field root string      absolute, normalized worktree root -- the registry key
---@field gitdir string    absolute git directory (per-worktree for linked worktrees)
---@field name string      basename of root, for the sidebar header
---@field oid? string      HEAD commit, nil on an unborn branch
---@field head? string     branch name, nil when detached
---@field detached boolean
---@field upstream? string
---@field ahead integer
---@field behind integer
local Repo = {}
Repo.__index = Repo

---@type table<string, gitvim.Repo>
local registry = {}

--- Directory -> worktree root, or false for "not in a repo". Detection spawns
--- git, and the sidebar asks on every buffer change, so the answer is cached.
---@type table<string, string|false>
local lookup = {}

--- The repository the sidebar is currently showing.
---@type string?
local active

---@param root string
---@param gitdir string
---@return gitvim.Repo
local function register(root, gitdir)
  local repo = registry[root]
  if repo then
    repo.gitdir = gitdir
    return repo
  end

  repo = setmetatable({
    root = root,
    gitdir = gitdir,
    name = vim.fs.basename(root),
    detached = false,
    ahead = 0,
    behind = 0,
  }, Repo)

  registry[root] = repo
  return repo
end

--- Apply a parsed status header to the repo's HEAD fields.
---@param branch gitvim.status.Branch
function Repo:set_branch(branch)
  self.oid = branch.oid
  self.head = branch.head
  self.detached = branch.detached
  self.upstream = branch.upstream
  self.ahead = branch.ahead
  self.behind = branch.behind
end

--- Refresh HEAD, upstream and ahead/behind without listing any files.
---@param cb fun(err?: gitvim.git.Error, repo?: gitvim.Repo)
function Repo:read_head(cb)
  status.get(self.root, { untracked = "no" }, function(err, result)
    if err then
      return cb(err, nil)
    end
    self:set_branch(result.branch)
    cb(nil, self)
  end)
end

--- Short display form of HEAD: the branch, or an abbreviated SHA when detached.
---@return string
function Repo:head_label()
  if self.head then
    return self.head
  end
  if self.oid then
    return self.oid:sub(1, 7)
  end
  return "(no commits)"
end

--- Resolve the directory a detection should start from.
---@param path? string  a file, a directory, or nil for the current buffer
---@return string
local function start_dir(path)
  if not path or path == "" then
    path = vim.api.nvim_buf_get_name(0)
  end
  if path == "" then
    return vim.fs.normalize(vim.uv.cwd() or ".")
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    return path
  end
  return vim.fs.dirname(path)
end

--- Find the repository containing `path`.
---
--- Answers from cache without spawning git when the directory has been seen
--- before; `forget()` invalidates.
---@param path? string
---@param cb fun(err?: gitvim.git.Error, repo?: gitvim.Repo)
function M.detect(path, cb)
  local dir = start_dir(path)

  local cached = lookup[dir]
  if cached ~= nil then
    if cached == false then
      return vim.schedule(function()
        cb({
          kind = "not_a_repo",
          message = "not a git repository: " .. dir,
          code = 128,
          signal = 0,
          stderr = "",
          args = { "rev-parse", "--show-toplevel" },
          cwd = dir,
        }, nil)
      end)
    end
    local repo = registry[cached]
    if repo then
      return vim.schedule(function()
        cb(nil, repo)
      end)
    end
  end

  -- --absolute-git-dir rather than --path-format=absolute: the latter needs
  -- git 2.31, the former has been there since 2.13.
  cli.run(
    { "rev-parse", "--show-toplevel", "--absolute-git-dir" },
    { cwd = dir },
    function(err, res)
      if err then
        if err.kind == "not_a_repo" then
          lookup[dir] = false
        end
        return cb(err, nil)
      end

      local lines = vim.split(vim.trim(res.stdout), "\n", { plain = true })
      local root = lines[1] and vim.fs.normalize(vim.trim(lines[1])) or nil
      local gitdir = lines[2] and vim.fs.normalize(vim.trim(lines[2])) or nil

      -- A bare repository has a gitdir but no worktree; gitvim is a worktree UI.
      if not root or root == "" then
        lookup[dir] = false
        return cb({
          kind = "not_a_repo",
          message = "no work tree for " .. dir,
          code = 128,
          signal = 0,
          stderr = res.stderr,
          args = { "rev-parse", "--show-toplevel" },
          cwd = dir,
        }, nil)
      end

      lookup[dir] = root
      cb(nil, register(root, gitdir or (root .. "/.git")))
    end
  )
end

--- The already-registered repo for a root, if any.
---@param root string
---@return gitvim.Repo?
function M.get(root)
  return registry[vim.fs.normalize(root)]
end

---@return table<string, gitvim.Repo>
function M.all()
  return registry
end

--- Drop a cached detection result, e.g. after `git init` in a watched directory.
---@param path? string  nil clears every cached lookup
function M.forget(path)
  if path then
    lookup[start_dir(path)] = nil
  else
    lookup = {}
  end
end

--- The repository the sidebar is showing.
---@return gitvim.Repo?
function M.active()
  return active and registry[active] or nil
end

---@param root string
function M.set_active(root)
  active = vim.fs.normalize(root)
end

--- Clear the registry. Tests only.
function M.reset()
  registry = {}
  lookup = {}
  active = nil
end

return M
