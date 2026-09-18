--- `git status --porcelain=v2` parsing.
---
--- One spawn yields everything the SCM tab needs: per-file XY codes, rename
--- scores, submodule state, and the branch/upstream/ahead-behind header.
---
--- `parse()` is pure, so the whole format is testable without spawning git.

local cli = require("gitvim.git.cli")

local M = {}

---@alias gitvim.status.Group "merge"|"staged"|"changes"|"untracked"|"ignored"

---@alias gitvim.status.Kind
---| "modified" | "added" | "deleted" | "renamed" | "copied"
---| "typechange" | "untracked" | "ignored" | "conflict"

---@class gitvim.status.Submodule
---@field commit boolean    the submodule's checked-out commit changed
---@field modified boolean  it has modified tracked content
---@field untracked boolean it has untracked content

---@class gitvim.status.Entry
---@field path string                    worktree-relative, raw UTF-8
---@field orig_path? string              source path of a rename or copy
---@field x string                       index status letter, "." when unchanged
---@field y string                       worktree status letter, "." when unchanged
---@field group gitvim.status.Group
---@field kind gitvim.status.Kind
---@field score? integer                 rename/copy similarity, 0-100
---@field submodule? gitvim.status.Submodule
---@field conflict? string               the unmerged XY pair, e.g. "UU"

---@class gitvim.status.Branch
---@field oid? string        HEAD commit, nil on an unborn branch
---@field head? string       branch name, nil when detached
---@field detached boolean
---@field upstream? string
---@field ahead integer
---@field behind integer

---@class gitvim.status.Result
---@field branch gitvim.status.Branch
---@field entries gitvim.status.Entry[]

--- Status letter -> kind. Shared by the index and worktree columns.
local KIND = {
  M = "modified",
  A = "added",
  D = "deleted",
  R = "renamed",
  C = "copied",
  T = "typechange",
}

--- Porcelain v2 record shapes. `XY` is always exactly two bytes, and the path
--- is whatever remains -- it may contain spaces, so it cannot be tokenized.
local ORDINARY = "^1 (..) (%S+) %S+ %S+ %S+ %S+ %S+ (.+)$"
local RENAMED = "^2 (..) (%S+) %S+ %S+ %S+ %S+ %S+ (%a)(%d+) (.+)$"
local UNMERGED = "^u (..) (%S+) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$"

--- Parse the `<sub>` field: `N...` for a plain file, `S<c><m><u>` for a submodule.
---@param field string
---@return gitvim.status.Submodule?
local function parse_submodule(field)
  if field:sub(1, 1) ~= "S" then
    return nil
  end
  return {
    commit = field:sub(2, 2) == "C",
    modified = field:sub(3, 3) == "M",
    untracked = field:sub(4, 4) == "U",
  }
end

---@param branch gitvim.status.Branch
---@param line string
local function parse_header(branch, line)
  local key, value = line:match("^# (%S+) (.*)$")
  if not key then
    return
  end

  if key == "branch.oid" then
    -- "(initial)" on an unborn branch: there is no commit to name.
    branch.oid = value ~= "(initial)" and value or nil
  elseif key == "branch.head" then
    if value == "(detached)" then
      branch.detached = true
    else
      branch.head = value
    end
  elseif key == "branch.upstream" then
    branch.upstream = value
  elseif key == "branch.ab" then
    local ahead, behind = value:match("^%+(%d+) %-(%d+)$")
    branch.ahead = tonumber(ahead) or 0
    branch.behind = tonumber(behind) or 0
  end
end

--- Build the entries a single tracked record contributes.
---
--- A file staged *and* then modified again (XY = "AM") is genuinely in two
--- groups at once, exactly as VS Code shows it, so it yields two entries: the
--- index side and the worktree side, each with its own kind.
---@param base gitvim.status.Entry
---@param out gitvim.status.Entry[]
local function emit_tracked(base, out)
  if base.x ~= "." then
    local staged = vim.tbl_extend("force", {}, base)
    staged.group = "staged"
    staged.kind = KIND[base.x] or "modified"
    table.insert(out, staged)
  end
  if base.y ~= "." then
    local changes = vim.tbl_extend("force", {}, base)
    changes.group = "changes"
    changes.kind = KIND[base.y] or "modified"
    -- The worktree change applies to the destination path; only the index
    -- side carries the rename itself.
    if changes.kind ~= "renamed" and changes.kind ~= "copied" then
      changes.score = nil
    end
    table.insert(out, changes)
  end
end

--- Parse the raw stdout of the status command. Pure: no editor or git calls.
---@param stdout string  NUL-delimited `--porcelain=v2 --branch -z` output
---@return gitvim.status.Result
function M.parse(stdout)
  ---@type gitvim.status.Branch
  local branch = { detached = false, ahead = 0, behind = 0 }
  ---@type gitvim.status.Entry[]
  local entries = {}

  local fields = cli.split_nul(stdout)
  local i = 1
  while i <= #fields do
    local rec = fields[i]
    local tag = rec:sub(1, 1)

    if tag == "#" then
      parse_header(branch, rec)
    elseif tag == "1" then
      local xy, sub, path = rec:match(ORDINARY)
      if path then
        emit_tracked({
          path = path,
          x = xy:sub(1, 1),
          y = xy:sub(2, 2),
          submodule = parse_submodule(sub),
        }, entries)
      end
    elseif tag == "2" then
      -- Under -z the original path is not tab-joined onto the record: it is
      -- the very next NUL-terminated field. Consume it.
      local xy, sub, _, score, path = rec:match(RENAMED)
      if path then
        i = i + 1
        emit_tracked({
          path = path,
          orig_path = fields[i],
          x = xy:sub(1, 1),
          y = xy:sub(2, 2),
          score = tonumber(score),
          submodule = parse_submodule(sub),
        }, entries)
      end
    elseif tag == "u" then
      local xy, sub, path = rec:match(UNMERGED)
      if path then
        table.insert(entries, {
          path = path,
          x = xy:sub(1, 1),
          y = xy:sub(2, 2),
          group = "merge",
          kind = "conflict",
          conflict = xy,
          submodule = parse_submodule(sub),
        })
      end
    elseif tag == "?" then
      table.insert(entries, {
        path = rec:sub(3),
        x = "?",
        y = "?",
        group = "untracked",
        kind = "untracked",
      })
    elseif tag == "!" then
      table.insert(entries, {
        path = rec:sub(3),
        x = "!",
        y = "!",
        group = "ignored",
        kind = "ignored",
      })
    end

    i = i + 1
  end

  return { branch = branch, entries = entries }
end

--- Bucket entries by group, preserving git's ordering within each.
---@param result gitvim.status.Result
---@return table<gitvim.status.Group, gitvim.status.Entry[]>
function M.by_group(result)
  local groups = { merge = {}, staged = {}, changes = {}, untracked = {}, ignored = {} }
  for _, entry in ipairs(result.entries) do
    table.insert(groups[entry.group], entry)
  end
  return groups
end

---@class gitvim.status.Opts
---@field untracked? "all"|"normal"|"no"
---@field ignored? boolean

---@param opts? gitvim.status.Opts
---@return string[]
function M.args(opts)
  opts = opts or {}
  local args = {
    "status",
    "--porcelain=v2",
    "--branch",
    "--untracked-files=" .. (opts.untracked or "all"),
    "-z",
    "--ignore-submodules=none",
  }
  if opts.ignored then
    table.insert(args, "--ignored=matching")
  end
  return args
end

--- Fetch and parse the status of a repository.
---@param root string  worktree root
---@param opts? gitvim.status.Opts
---@param cb fun(err?: gitvim.git.Error, result?: gitvim.status.Result)
function M.get(root, opts, cb)
  cli.run(M.args(opts), { cwd = root }, function(err, res)
    if err then
      return cb(err, nil)
    end
    cb(nil, M.parse(res.stdout))
  end)
end

return M
