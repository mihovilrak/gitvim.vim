--- Stage, unstage and discard.
---
--- Every function takes status entries rather than bare paths: whether a path
--- is tracked decides how it is discarded, and a rename has to carry its old
--- path along or unstaging it would leave half the rename in the index.
---
--- Pathspecs are passed after `--` with `--literal-pathspecs`, so a file named
--- `*.lua` or `:(top)x` means exactly that file.

local cli = require("gitvim.git.cli")

local M = {}

---@param entries gitvim.status.Entry[]
---@return string[]
local function paths_of(entries)
  local out, seen = {}, {}
  local function add(path)
    if path and not seen[path] then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  for _, entry in ipairs(entries) do
    add(entry.orig_path)
    add(entry.path)
  end
  return out
end

--- Run `args -- paths`, or just `args` when `paths` is nil (the "all" form).
---@param root string
---@param args string[]
---@param paths? string[]
---@param cb fun(err?: gitvim.git.Error)
local function run(root, args, paths, cb)
  local full = { "--literal-pathspecs" }
  vim.list_extend(full, args)
  if paths then
    if #paths == 0 then
      vim.schedule(cb)
      return
    end
    full[#full + 1] = "--"
    vim.list_extend(full, paths)
  end
  cli.run(full, { cwd = root }, function(err)
    cb(err)
  end)
end

--- Add entries to the index. `-A` so a deleted file stages as a deletion.
---@param root string
---@param entries gitvim.status.Entry[]
---@param cb fun(err?: gitvim.git.Error)
function M.stage(root, entries, cb)
  run(root, { "add", "-A" }, paths_of(entries), cb)
end

--- Stage everything: tracked changes, deletions and untracked files.
---@param root string
---@param cb fun(err?: gitvim.git.Error)
function M.stage_all(root, cb)
  run(root, { "add", "-A", "--", "." }, nil, cb)
end

--- Take entries out of the index, leaving the working tree alone.
---
--- `reset` rather than `restore --staged`: it also works on an unborn branch,
--- where there is no HEAD for `restore` to restore from.
---@param root string
---@param entries gitvim.status.Entry[]
---@param cb fun(err?: gitvim.git.Error)
function M.unstage(root, entries, cb)
  run(root, { "reset", "-q" }, paths_of(entries), cb)
end

---@param root string
---@param cb fun(err?: gitvim.git.Error)
function M.unstage_all(root, cb)
  run(root, { "reset", "-q" }, nil, cb)
end

--- Throw away working-tree changes.
---
--- Tracked files go back to their index version (so a staged change survives,
--- as in VS Code); untracked files are deleted. Irreversible -- callers confirm.
---@param root string
---@param entries gitvim.status.Entry[]
---@param cb fun(err?: gitvim.git.Error)
function M.discard(root, entries, cb)
  local tracked, untracked = {}, {}
  for _, entry in ipairs(entries) do
    if entry.group == "untracked" then
      untracked[#untracked + 1] = entry
    elseif entry.group == "changes" then
      tracked[#tracked + 1] = entry
    end
  end

  run(root, { "restore", "--worktree" }, paths_of(tracked), function(err)
    if err then
      return cb(err)
    end
    run(root, { "clean", "-f", "-q" }, paths_of(untracked), cb)
  end)
end

--- Discard every working-tree change and delete every untracked file.
---
--- Ignored files are kept: `clean` without `-x` leaves them alone.
---@param root string
---@param cb fun(err?: gitvim.git.Error)
function M.discard_all(root, cb)
  run(root, { "restore", "--worktree", "--", "." }, nil, function(err)
    -- `restore` fails with a pathspec error when nothing is tracked yet.
    if err and err.kind ~= "bad_path" then
      return cb(err)
    end
    run(root, { "clean", "-f", "-q", "--", "." }, nil, cb)
  end)
end

return M
