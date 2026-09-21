--- Paged commit history for the graph.
---
--- Every field travels NUL-delimited, so a subject or author name may hold
--- any character but NUL. Pages are cut with `--skip`/`--max-count`; the
--- caller keeps the cursor `fetch` hands back and asks for the next page when
--- the view scrolls near the end.

local cli = require("gitvim.git.cli")

local M = {}

--- The empty tree, the left side of a root commit's diff.
M.EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

--- One record: a leading NUL, then the fields NUL-separated. `%s` is a single
--- line, so the newline git puts between records ends up on the subject.
local FIELDS = { "%H", "%P", "%D", "%an", "%at", "%s" }
local FORMAT = "--format=%x00" .. table.concat(FIELDS, "%x00")

---@alias gitvim.log.RefKind "head"|"local"|"remote"|"tag"

---@class gitvim.log.Ref
---@field kind gitvim.log.RefKind
---@field name string     short name: `main`, `origin/main`, `v1`, `HEAD`
---@field current? boolean  the branch HEAD points at

---@class gitvim.log.Commit
---@field sha string
---@field parents string[]
---@field refs gitvim.log.Ref[]
---@field author string
---@field time integer  author date, unix seconds
---@field subject string

---@class gitvim.log.Page
---@field commits gitvim.log.Commit[]
---@field next? integer  `skip` for the following page; nil at the end

---@class gitvim.log.File
---@field status string     one letter: A M D R C T
---@field path string
---@field orig? string      the path before a rename or copy

--- Parse `%D` as printed with `--decorate=full`. The current branch comes
--- first, then local branches, remotes and tags, each in git's order.
---@param decoration string
---@return gitvim.log.Ref[]
function M.parse_refs(decoration)
  local refs = {}
  local rank = { head = 1, ["local"] = 2, remote = 3, tag = 4 }
  for item in vim.gsplit(decoration, ", ", { plain = true }) do
    local current = item:match("^HEAD %-> (.+)$")
    local full = current or item:gsub("^tag: ", "")
    local ref
    if item == "HEAD" then
      ref = { kind = "head", name = "HEAD" }
    elseif full:match("^refs/heads/") then
      ref =
        { kind = "local", name = full:sub(#"refs/heads/" + 1), current = current and true or nil }
    elseif full:match("^refs/remotes/") and not full:match("/HEAD$") then
      ref = { kind = "remote", name = full:sub(#"refs/remotes/" + 1) }
    elseif full:match("^refs/tags/") then
      ref = { kind = "tag", name = full:sub(#"refs/tags/" + 1) }
    end
    -- refs/stash, refs/notes and the like are not badges.
    if ref then
      refs[#refs + 1] = ref
    end
  end
  for i, ref in ipairs(refs) do
    ref.order = i
  end
  table.sort(refs, function(a, b)
    local ra = a.current and 0 or rank[a.kind]
    local rb = b.current and 0 or rank[b.kind]
    if ra ~= rb then
      return ra < rb
    end
    return a.order < b.order
  end)
  for _, ref in ipairs(refs) do
    ref.order = nil
  end
  return refs
end

--- Parse `git log` output in `FORMAT`.
---@param out string
---@return gitvim.log.Commit[]
function M.parse(out)
  local fields = vim.split(out, "\0", { plain = true })
  local commits = {}
  -- fields[1] is the empty string before the first record's leading NUL.
  for i = 2, #fields - #FIELDS + 1, #FIELDS do
    local parents = fields[i + 1] == "" and {} or vim.split(fields[i + 1], " ", { plain = true })
    commits[#commits + 1] = {
      sha = fields[i],
      parents = parents,
      refs = M.parse_refs(fields[i + 2]),
      author = fields[i + 3],
      time = tonumber(fields[i + 4]) or 0,
      subject = (fields[i + 5]:gsub("\n$", "")),
    }
  end
  return commits
end

--- The `git log` arguments for one page. Exposed for the specs.
---@param skip integer
---@param max integer
---@return string[]
function M.args(skip, max)
  return {
    "log",
    "--date-order",
    "--decorate=full",
    FORMAT,
    "--skip=" .. skip,
    "--max-count=" .. max,
    "--branches",
    "--remotes",
    "--tags",
    "HEAD",
    "--",
  }
end

--- One page of history across all branches, remotes and tags, newest first.
--- An unborn HEAD is an empty history, not an error.
---@param root string
---@param opts { skip?: integer, max: integer }
---@param cb fun(err?: gitvim.git.Error, page?: gitvim.log.Page)
function M.fetch(root, opts, cb)
  local skip = opts.skip or 0
  cli.run(M.args(skip, opts.max), { cwd = root }, function(err, res)
    if err then
      if err.kind == "bad_revision" then
        cb(nil, { commits = {} })
      else
        cb(err)
      end
      return
    end
    local commits = M.parse(res.stdout)
    local full = #commits >= opts.max
    cb(nil, { commits = commits, next = full and skip + #commits or nil })
  end)
end

--- Parse `diff-tree -z --name-status` output.
---@param out string
---@return gitvim.log.File[]
function M.parse_files(out)
  local fields = cli.split_nul(out)
  local files = {}
  local i = 1
  while i <= #fields do
    local status = fields[i]:sub(1, 1)
    if status == "R" or status == "C" then
      files[#files + 1] = { status = status, orig = fields[i + 1], path = fields[i + 2] }
      i = i + 3
    else
      files[#files + 1] = { status = status, path = fields[i + 1] }
      i = i + 2
    end
  end
  return files
end

--- The revision a commit's changes are shown against: its first parent, or
--- the empty tree for a root commit. A merge is diffed against the branch it
--- was merged into, the way `git show --first-parent` reads it.
---@param commit { parents: string[] }
---@return string
function M.base(commit)
  return commit.parents[1] or M.EMPTY_TREE
end

--- The files a commit changed.
---@param root string
---@param commit { sha: string, parents: string[] }
---@param cb fun(err?: gitvim.git.Error, files?: gitvim.log.File[])
function M.files(root, commit, cb)
  cli.run(
    { "diff-tree", "-r", "-z", "-M", "--name-status", "--no-commit-id", M.base(commit), commit.sha },
    { cwd = root },
    function(err, res)
      if err then
        cb(err)
        return
      end
      cb(nil, M.parse_files(res.stdout))
    end
  )
end

return M
