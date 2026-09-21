--- Paged commit history for the graph, and one file's history for the
--- timeline.
---
--- Every field travels NUL-delimited, so a subject or author name may hold
--- any character but NUL. Graph pages are cut with `--skip`/`--max-count`;
--- the caller keeps the cursor `fetch` hands back and asks for the next page
--- when the view scrolls near the end. A file's history is read from one
--- paused `git log` instead, see `history`.

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

---@class gitvim.log.Revision: gitvim.log.Commit
---@field file? gitvim.log.File  the followed file in this commit; nil for a
---                              commit that did not touch it (a merge)

---@class gitvim.log.History
---@field commits gitvim.log.Revision[]
---@field next? integer  revisions read so far, while more remain; nil at the end

--- The `git log` arguments for a file's whole history. Exposed for the specs.
---
--- There is no `--skip`: `--follow` spots a rename only in the commits it
--- shows, so a skipped rename leaves it following a name older revisions
--- never had. `history` reads the output a page at a time instead.
---@param path string  relative to the worktree root
---@param follow boolean  follow the file across renames
---@return string[]
function M.history_args(path, follow)
  local args = { "log", "--decorate=full", FORMAT, "--name-status", "-z", "-M" }
  if follow then
    args[#args + 1] = "--follow"
  end
  vim.list_extend(args, { "--", path })
  return args
end

--- One record of `history_args` output from `fields[i]` on: the `FORMAT`
--- fields, then -- unless the commit left the file alone -- a name-status
--- entry whose first field starts with the newline git puts after the
--- format. The next record's leading NUL leaves an empty field after it.
---@param fields string[]
---@param i integer
---@return gitvim.log.Revision commit
---@return integer next  the index of the next record's first field
local function parse_record(fields, i)
  local parents = fields[i + 1] == "" and {} or vim.split(fields[i + 1], " ", { plain = true })
  ---@type gitvim.log.Revision
  local commit = {
    sha = fields[i],
    parents = parents,
    refs = M.parse_refs(fields[i + 2]),
    author = fields[i + 3],
    time = tonumber(fields[i + 4]) or 0,
    subject = (fields[i + 5]:gsub("\n$", "")),
  }
  i = i + #FIELDS
  local status = (fields[i] or ""):gsub("^\n", "")
  if status ~= "" then
    local letter = status:sub(1, 1)
    if letter == "R" or letter == "C" then
      commit.file = { status = letter, orig = fields[i + 1], path = fields[i + 2] }
      i = i + 3
    else
      commit.file = { status = letter, path = fields[i + 1] }
      i = i + 2
    end
  end
  -- Skip the empty field before the next record's first one.
  return commit, i + 1
end

--- Parse the whole of `history_args` output.
---@param out string
---@return gitvim.log.Revision[]
function M.parse_history(out)
  local fields = vim.split(out, "\0", { plain = true })
  local commits = {}
  local i = 2
  while i + #FIELDS - 1 <= #fields do
    commits[#commits + 1], i = parse_record(fields, i)
  end
  return commits
end

--- Parse the records `buf` holds in full off its front, for output read a
--- chunk at a time. A record is whole once the empty field after it is:
--- until then, a name-status entry may still be on its way.
---@param buf string  starts at a record's leading NUL
---@return gitvim.log.Revision[] commits
---@return string rest  the unparsed tail, again at a leading NUL
function M.parse_history_prefix(buf)
  local fields = vim.split(buf, "\0", { plain = true })
  local commits = {}
  local i = 2
  -- The last field is cut off at the end of `buf`, so it does not count.
  while i + #FIELDS < #fields do
    local commit, next = parse_record(fields, i)
    if next > #fields then
      break
    end
    commits[#commits + 1], i = commit, next
  end
  return commits, table.concat(fields, "\0", i - 1)
end

--- How long a paused `git log` may sit before it is ended, in ms. It holds
--- the pack files open meanwhile, which on Windows keeps `git gc` from
--- deleting them. Reading on after that restarts it, dropping what was read.
M.idle_ms = 30000

---@class gitvim.log.HistoryReader
---@field private root string
---@field private args string[]
---@field private proc? gitvim.git.Stream  the running `git log`
---@field private buf string               its output not parsed yet
---@field private drop integer             its records to drop: already read before a restart
---@field private position integer         records read from the top
---@field private queue gitvim.log.Revision[]  read, not yet handed out
---@field private handed integer           revisions handed out
---@field private done boolean             every record is read
---@field private err? gitvim.git.Error
---@field private want? { max: integer, cb: fun(err?: gitvim.git.Error, page?: gitvim.log.History) }
---@field private timer? uv.uv_timer_t
local Reader = {}
Reader.__index = Reader

--- A file's history, newest first, read a page at a time from one `git log`
--- that is paused between pages, so no revision is walked twice. An unborn
--- HEAD is an empty history, not an error. `close` it once done with.
---@param root string
---@param path string  relative to `root`
---@param opts? { follow?: boolean }
---@return gitvim.log.HistoryReader
function M.history(root, path, opts)
  return setmetatable({
    root = root,
    args = M.history_args(path, not opts or opts.follow ~= false),
    buf = "",
    drop = 0,
    position = 0,
    queue = {},
    handed = 0,
    done = false,
  }, Reader)
end

--- Hand the next `max` revisions to `cb`, on the main loop. A page is only
--- handed over once the one after it has begun, or the history has ended,
--- so `next` is nil exactly at the end. One read at a time.
---@param max integer
---@param cb fun(err?: gitvim.git.Error, page?: gitvim.log.History)
function Reader:read(max, cb)
  assert(not self.want, "gitvim: one history read at a time")
  self.want = { max = max, cb = cb }
  if self.timer then
    self.timer:stop()
  end
  if self.err then
    -- Retry: restart past whatever was read before the failure.
    self.err = nil
    self.proc = nil
  end
  self:pump()
end

--- Stop reading: end `git log`, and drop the read in flight.
function Reader:close()
  self.want = nil
  self:stop()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

---@private
function Reader:stop()
  if self.proc then
    self.proc.kill()
    self.proc = nil
  end
end

---@private
function Reader:spawn()
  self.buf = ""
  self.drop = self.position
  local proc
  proc = require("gitvim.git.cli").stream(self.args, { cwd = self.root }, function(chunk)
    if self.proc ~= proc then
      return
    end
    local commits
    commits, self.buf = M.parse_history_prefix(self.buf .. chunk)
    self:take(commits)
    self:pump()
  end, function(err)
    if self.proc ~= proc then
      return
    end
    self.proc = nil
    if err and err.kind ~= "bad_revision" then
      self.err = err
    else
      self.done = true
      self:take(M.parse_history(self.buf))
      self.buf = ""
    end
    self:pump()
  end)
  self.proc = proc
end

---@private
---@param commits gitvim.log.Revision[]
function Reader:take(commits)
  for _, commit in ipairs(commits) do
    if self.drop > 0 then
      self.drop = self.drop - 1
    else
      self.position = self.position + 1
      self.queue[#self.queue + 1] = commit
    end
  end
end

--- Hand over the read waiting, if it can be; otherwise keep git going.
---@private
function Reader:pump()
  local want = self.want
  if not want then
    if self.proc then
      self.proc.pause()
    end
    return
  end
  if self.err then
    self.want = nil
    local err = self.err
    vim.schedule(function()
      want.cb(err)
    end)
    return
  end
  if #self.queue > want.max or self.done then
    self.want = nil
    local commits = vim.list_slice(self.queue, 1, want.max)
    self.queue = vim.list_slice(self.queue, want.max + 1)
    self.handed = self.handed + #commits
    local more = #self.queue > 0 or not self.done
    if self.proc then
      self.proc.pause()
      self:idle()
    end
    vim.schedule(function()
      want.cb(nil, { commits = commits, next = more and self.handed or nil })
    end)
    return
  end
  if not self.proc then
    self:spawn()
  end
  self.proc.resume()
end

--- End the paused `git log` if nobody reads on for `idle_ms`.
---@private
function Reader:idle()
  self.timer = self.timer or vim.uv.new_timer()
  self.timer:start(
    M.idle_ms,
    0,
    vim.schedule_wrap(function()
      if not self.want then
        self:stop()
      end
    end)
  )
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
