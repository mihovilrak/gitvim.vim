--- Hunk-level reads and writes for the review view.
---
--- A review compares two *sides* — a blob (a revision or the index) and
--- usually the working tree — and every per-hunk operation is the same move:
--- splice one hunk's lines from one side into the other and write the result
--- back. Staging writes a new index blob with `hash-object` + `update-index`,
--- so no patch is ever built and nothing depends on `git apply` agreeing with
--- how the hunk was computed; reverting rewrites the file on disk.
---
--- Sides are read byte-exact (`text = false`) and their line endings are
--- remembered, so a CRLF file is diffed line by line — not as one whole-file
--- change — and is written back with the endings it came with.

local cli = require("gitvim.git.cli")

local M = {}

--- The index, as a revision argument.
M.INDEX = ":"

--- Bytes sniffed for a NUL, git's own binary heuristic.
local SNIFF = 8000

---@class gitvim.hunk.Side
---@field lines string[]   without terminators
---@field eol string       "\n" or "\r\n"
---@field noeol boolean    the last line has no terminator
---@field missing boolean  the path does not exist on this side
---@field binary boolean
---@field special? string  "symlink" / "directory" / "submodule": shown, never diffed

--- One change, in `vim.diff` "indices" form. A zero count means an insertion
--- or deletion *after* line `start` (0 = before the first line).
---@class gitvim.hunk.Hunk
---@field a_start integer
---@field a_count integer
---@field b_start integer
---@field b_count integer

--- Split raw bytes into a side.
---@param text string
---@return gitvim.hunk.Side
function M.parse(text)
  local side = { lines = {}, eol = "\n", noeol = false, missing = false, binary = false }
  if text:sub(1, SNIFF):find("\0", 1, true) then
    side.binary = true
    return side
  end
  if text == "" then
    return side
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  else
    side.noeol = true
  end
  -- Only a file whose every terminated line ends in CR is CRLF. A mixed file
  -- keeps its stray CRs as content, so writing it back cannot normalise it.
  local terminated = side.noeol and #lines - 1 or #lines
  local crlf = terminated > 0
  for i = 1, terminated do
    if lines[i]:sub(-1) ~= "\r" then
      crlf = false
      break
    end
  end
  if crlf then
    side.eol = "\r\n"
    for i = 1, terminated do
      lines[i] = lines[i]:sub(1, -2)
    end
  end
  side.lines = lines
  return side
end

---@param special? string
---@return gitvim.hunk.Side
local function absent(special)
  return {
    lines = {},
    eol = "\n",
    noeol = false,
    missing = special == nil,
    binary = false,
    special = special,
  }
end

--- Bytes for a list of lines, in a side's line-ending style.
---@param lines string[]
---@param eol string
---@param noeol boolean
---@return string
function M.serialize(lines, eol, noeol)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, eol) .. (noeol and "" or eol)
end

--- Read one side of a review.
---@param root string
---@param rev? string   nil = working tree, `M.INDEX` = the index, else a revision
---@param path string   repository-relative
---@param cb fun(side: gitvim.hunk.Side)
function M.read(root, rev, path, cb)
  if rev == nil then
    local file = root .. "/" .. path
    local stat = vim.uv.fs_lstat(file)
    if not stat then
      vim.schedule_wrap(cb)(absent())
    elseif stat.type == "link" then
      vim.schedule_wrap(cb)(absent("symlink"))
    elseif stat.type == "directory" then
      vim.schedule_wrap(cb)(absent("directory"))
    else
      local fd = io.open(file, "rb")
      local text = fd and fd:read("*a") or ""
      if fd then
        fd:close()
      end
      vim.schedule_wrap(cb)(M.parse(text))
    end
    return
  end
  local object = (rev == M.INDEX and ":" or rev .. ":") .. path
  cli.run({ "cat-file", "-t", object }, { cwd = root }, function(err, res)
    if err then
      cb(absent())
      return
    end
    local kind = vim.trim(res.stdout)
    if kind ~= "blob" then
      cb(absent(kind == "tree" and "directory" or kind == "commit" and "submodule" or kind))
      return
    end
    cli.run({ "cat-file", "blob", object }, { cwd = root, text = false }, function(berr, bres)
      cb(berr and absent() or M.parse(bres.stdout))
    end)
  end)
end

--- Parse `algorithm:` and `indent-heuristic` out of a 'diffopt' list, so the
--- hunks here match the ones diff mode draws.
---@param diffopt? string[]
---@return table
local function diff_opts(diffopt)
  local opts = { result_type = "indices" }
  for _, item in ipairs(diffopt or {}) do
    local algorithm = item:match("^algorithm:(%a+)$")
    if algorithm then
      opts.algorithm = algorithm
    elseif item == "indent-heuristic" then
      opts.indent_heuristic = true
    end
  end
  return opts
end

---@param side gitvim.hunk.Side
---@return string
local function diff_text(side)
  return #side.lines == 0 and "" or table.concat(side.lines, "\n") .. "\n"
end

--- The hunks between two sides. Binary and special sides have none.
---@param a gitvim.hunk.Side
---@param b gitvim.hunk.Side
---@param diffopt? string[]
---@return gitvim.hunk.Hunk[]
function M.compute(a, b, diffopt)
  if a.binary or b.binary or a.special or b.special then
    return {}
  end
  local out = {}
  local raw = vim.diff(diff_text(a), diff_text(b), diff_opts(diffopt)) --[[@as integer[][] ]]
  for _, h in ipairs(raw) do
    out[#out + 1] = { a_start = h[1], a_count = h[2], b_start = h[3], b_count = h[4] }
  end
  return out
end

--- The first and last line a hunk covers on one side, for cursors and marks.
--- A pure insertion/deletion sits on the line it follows (at least line 1).
---@param hunk gitvim.hunk.Hunk
---@param which "a"|"b"
---@return integer first
---@return integer last
function M.range(hunk, which)
  local start, count = hunk[which .. "_start"], hunk[which .. "_count"]
  if count == 0 then
    local line = math.max(start, 1)
    return line, line
  end
  return start, start + count - 1
end

---@param lines string[]
---@param start integer
---@param count integer
---@return string[]
local function slice(lines, start, count)
  return count == 0 and {} or vim.list_slice(lines, start, start + count - 1)
end

--- `lines` with `count` lines from `start` replaced by `repl` (a zero count
--- inserts after `start`).
---@param lines string[]
---@param start integer
---@param count integer
---@param repl string[]
---@return string[]
local function splice(lines, start, count, repl)
  local first = count == 0 and start + 1 or start
  local out = vim.list_slice(lines, 1, first - 1)
  vim.list_extend(out, repl)
  vim.list_extend(out, lines, first + count)
  return out
end

--- Copy one hunk across: the bytes `to` would hold with this hunk's lines
--- taken from `from`. `forward` carries b's version into a (stage); otherwise
--- a's version into b (revert, unstage).
---@param a gitvim.hunk.Side
---@param b gitvim.hunk.Side
---@param hunk gitvim.hunk.Hunk
---@param forward boolean
---@return string content
---@return string[] lines
function M.apply(a, b, hunk, forward)
  local from, to = b, a
  local fs, fc, ts, tc = hunk.b_start, hunk.b_count, hunk.a_start, hunk.a_count
  if not forward then
    from, to = a, b
    fs, fc, ts, tc = hunk.a_start, hunk.a_count, hunk.b_start, hunk.b_count
  end
  local lines = splice(to.lines, ts, tc, slice(from.lines, fs, fc))
  -- The final line's terminator belongs to whichever side supplied it.
  local noeol = to.noeol
  if fs + fc - 1 >= #from.lines and ts + tc - 1 >= #to.lines then
    noeol = from.noeol
  end
  local eol = to.missing and from.eol or to.eol
  return M.serialize(lines, eol, noeol), lines
end

--- The file mode to write `path` into the index with: its index entry's,
--- else its mode in `rev`, else the working tree's executable bit.
---@param root string
---@param path string
---@param rev? string
---@param cb fun(mode: string)
local function file_mode(root, path, rev, cb)
  local function from_worktree()
    local stat = vim.uv.fs_stat(root .. "/" .. path)
    local exec = stat and bit.band(stat.mode, tonumber("111", 8)) ~= 0
    cb(exec and "100755" or "100644")
  end
  cli.run(
    { "--literal-pathspecs", "ls-files", "-s", "-z", "--", path },
    { cwd = root },
    function(err, res)
      local mode = not err and res.stdout:match("^(%d+) ")
      if mode then
        cb(mode)
      elseif rev and rev ~= M.INDEX then
        cli.run(
          { "--literal-pathspecs", "ls-tree", "-z", rev, "--", path },
          { cwd = root },
          function(terr, tres)
            local tmode = not terr and tres.stdout:match("^(%d+) ")
            if tmode then
              cb(tmode)
            else
              from_worktree()
            end
          end
        )
      else
        from_worktree()
      end
    end
  )
end

--- Put `content` into the index at `path`, or drop the entry when `remove`.
---@param root string
---@param path string
---@param content string
---@param remove boolean
---@param rev? string   where to look up the mode when the index has none
---@param cb fun(err?: gitvim.git.Error)
local function write_index(root, path, content, remove, rev, cb)
  if remove then
    cli.run({ "update-index", "--force-remove", "--", path }, { cwd = root }, function(err)
      cb(err)
    end)
    return
  end
  file_mode(root, path, rev, function(mode)
    cli.run({ "hash-object", "-w", "--stdin" }, { cwd = root, stdin = content }, function(err, res)
      if err then
        cb(err)
        return
      end
      local sha = vim.trim(res.stdout)
      cli.run(
        { "update-index", "--add", "--cacheinfo", ("%s,%s,%s"):format(mode, sha, path) },
        { cwd = root },
        function(uerr)
          cb(uerr)
        end
      )
    end)
  end)
end

--- Stage one hunk of an index (a) vs working tree (b) review.
---@param root string
---@param path string
---@param a gitvim.hunk.Side  the index
---@param b gitvim.hunk.Side  the working tree
---@param hunk gitvim.hunk.Hunk
---@param cb fun(err?: gitvim.git.Error)
function M.stage(root, path, a, b, hunk, cb)
  local content, lines = M.apply(a, b, hunk, true)
  -- The last hunk of a deleted file stages the deletion itself.
  write_index(root, path, content, b.missing and #lines == 0, nil, cb)
end

--- Unstage one hunk of a revision (a) vs index (b) review.
---@param root string
---@param path string
---@param a gitvim.hunk.Side  the revision, usually HEAD
---@param b gitvim.hunk.Side  the index
---@param hunk gitvim.hunk.Hunk
---@param rev string          a's revision, for the file mode
---@param cb fun(err?: gitvim.git.Error)
function M.unstage(root, path, a, b, hunk, rev, cb)
  local content, lines = M.apply(a, b, hunk, false)
  -- Unstaging the last hunk of an added file un-adds it.
  write_index(root, path, content, a.missing and #lines == 0, rev, cb)
end

--- Revert one hunk of the working tree (b) to a's version of it.
---@param root string
---@param path string
---@param a gitvim.hunk.Side
---@param b gitvim.hunk.Side  the working tree
---@param hunk gitvim.hunk.Hunk
---@param cb fun(err?: gitvim.git.Error)
function M.revert(root, path, a, b, hunk, cb)
  local content, lines = M.apply(a, b, hunk, false)
  local file = root .. "/" .. path
  local ok, err
  if a.missing and #lines == 0 then
    -- Reverting the only hunk of a new file removes the file.
    ok, err = os.remove(file)
  else
    vim.fn.mkdir(vim.fs.dirname(file), "p")
    local fd
    fd, err = io.open(file, "wb")
    if fd then
      ok, err = fd:write(content)
      fd:close()
    end
  end
  vim.schedule(function()
    if ok then
      cb(nil)
      return
    end
    local message = tostring(err)
    cb({
      kind = "unknown",
      message = message,
      code = -1,
      signal = 0,
      stderr = message,
      args = {},
      cwd = root,
    })
  end)
end

return M
