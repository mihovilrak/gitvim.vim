--- Search the work tree: ripgrep when it is installed, `git grep` otherwise.
---
--- Both backends are streamed and stop at `search.max_results`, so a pattern
--- that matches half the repository costs a screenful of work rather than a
--- frozen editor. Results come back grouped by file, each matching line once,
--- with the byte span of every match on it -- which is what the Search tab
--- highlights and what replace rewrites.
---
--- The two backends are made to agree on everything the form can express:
--- case, whole word, regex, and the include / exclude globs. What they cannot
--- agree on is regex dialect (Rust's vs PCRE) and capture groups in the
--- replacement, which only ripgrep expands.

local cli = require("gitvim.git.cli")

local M = {}

---@alias gitvim.grep.Backend "rg"|"git"

---@class gitvim.grep.Query
---@field pattern string
---@field replace? string  only consulted by ripgrep, for `$1`-style expansion
---@field case boolean     match case
---@field word boolean     whole word
---@field regex boolean    treat the pattern as a regular expression
---@field include string   comma-separated globs
---@field exclude string   comma-separated globs
---@field max? integer     stop after this many matches (default search.max_results)

---@class gitvim.grep.Span
---@field start integer  0-based byte offset into the line
---@field stop integer   exclusive
---@field rep? string    ripgrep's expansion of the replacement, regex mode only

---@class gitvim.grep.Line
---@field lnum integer
---@field text string    the line as it was on disk, newline stripped
---@field spans gitvim.grep.Span[]

---@class gitvim.grep.File
---@field path string    relative to the repository root
---@field lines gitvim.grep.Line[]
---@field count integer  matches, not lines

---@class gitvim.grep.Result
---@field backend gitvim.grep.Backend
---@field files gitvim.grep.File[]  in the order the backend reported them
---@field count integer             total matches
---@field truncated boolean         the cap was hit; there are more

---@class gitvim.grep.Handle
---@field cancel fun()  stop searching; the callback will never run

--- Tests pin a backend here; nil means "ripgrep if it is on PATH".
---@type gitvim.grep.Backend?
M.force = nil

---@return gitvim.grep.Backend
function M.backend()
  if M.force then
    return M.force
  end
  return vim.fn.executable("rg") == 1 and "rg" or "git"
end

--- Split a comma-separated glob list, as VS Code's filter boxes take it.
---@param s string?
---@return string[]
function M.globs(s)
  local out = {}
  for _, glob in ipairs(vim.split(s or "", ",", { plain = true })) do
    glob = vim.trim(glob)
    if glob ~= "" then
      out[#out + 1] = glob
    end
  end
  return out
end

--- ripgrep's argv for a query.
---
--- `--hidden` with `.git` excluded, because `git grep` searches tracked
--- dotfiles and the two must find the same things. `--sort path` costs
--- ripgrep its parallelism but makes the result order stable, which a list
--- the user is working down needs more than the speed.
---@param q gitvim.grep.Query
---@return string[]
function M.rg_args(q)
  local args = {
    "rg",
    "--json",
    "--no-config",
    "--hidden",
    "--sort",
    "path",
    "--glob",
    "!.git",
    q.case and "--case-sensitive" or "--ignore-case",
  }
  if q.word then
    args[#args + 1] = "--word-regexp"
  end
  if not q.regex then
    args[#args + 1] = "--fixed-strings"
  elseif q.replace and q.replace ~= "" then
    -- Only in regex mode: `--fixed-strings` would still expand `$1` in the
    -- replacement, which is not what a plain-text replace means.
    vim.list_extend(args, { "--replace", q.replace })
  end
  for _, glob in ipairs(M.globs(q.include)) do
    vim.list_extend(args, { "--glob", glob })
  end
  for _, glob in ipairs(M.globs(q.exclude)) do
    vim.list_extend(args, { "--glob", "!" .. glob })
  end
  vim.list_extend(args, { "--regexp", q.pattern, "--", "." })
  return args
end

--- Translate a ripgrep (gitignore-style) glob into `git grep` pathspecs.
---
--- A glob without a slash matches at any depth, and excluding a directory
--- excludes everything inside it; `:(glob)` pathspecs do neither by
--- themselves, so both are spelled out. An include glob naming a directory
--- does not pull in its contents, as in ripgrep: `docs/**` does that.
---@param glob string
---@param exclude boolean
---@return string[]
local function pathspecs(glob, exclude)
  local magic = exclude and ":(exclude,glob)" or ":(glob)"
  glob = glob:gsub("^%./", ""):gsub("/$", "")
  if glob:find("/", 1, true) then
    glob = glob:gsub("^/", "")
  else
    glob = "**/" .. glob
  end
  if not exclude then
    return { magic .. glob }
  end
  return { magic .. glob, magic .. glob .. "/**" }
end

--- `git grep`'s argv for a query, without the leading "git".
---
--- `-o` prints every match on its own record, which is the only way to learn
--- where the second match on a line is: `--column` alongside it reports
--- wrong offsets, so the spans are found again in the line text instead.
---@param q gitvim.grep.Query
---@param flavor? "-P"|"-E"  regex dialect; PCRE unless git was built without it
---@return string[]
function M.git_args(q, flavor)
  local args = { "grep", "-z", "-n", "-o", "-I", "--untracked", "--no-color" }
  if not q.case then
    args[#args + 1] = "-i"
  end
  if q.word then
    args[#args + 1] = "-w"
  end
  args[#args + 1] = q.regex and (flavor or "-P") or "-F"
  vim.list_extend(args, { "-e", q.pattern, "--" })
  for _, glob in ipairs(M.globs(q.include)) do
    vim.list_extend(args, pathspecs(glob, false))
  end
  for _, glob in ipairs(M.globs(q.exclude)) do
    vim.list_extend(args, pathspecs(glob, true))
  end
  return args
end

--- Strip the "./" ripgrep puts in front of every path when handed ".".
---@param path string
---@return string
local function relative(path)
  return (path:gsub("^%./", ""))
end

--- A ripgrep JSON text field, which is `{ text }` for UTF-8 and `{ bytes }`
--- (base64) for anything else.
---@param field? { text?: string, bytes?: string }
---@return string?
local function json_text(field)
  if not field then
    return nil
  end
  if field.text then
    return field.text
  end
  if field.bytes then
    local ok, decoded = pcall(vim.base64.decode, field.bytes)
    return ok and decoded or nil
  end
end

--- Parse one line of `rg --json`. Nil for everything that is not a match
--- (begin/end/summary records).
---@param json string
---@return string? path, gitvim.grep.Line? line
function M.parse_rg(json)
  local ok, msg = pcall(vim.json.decode, json)
  if not ok or type(msg) ~= "table" or msg.type ~= "match" then
    return nil, nil
  end
  local data = msg.data
  local path, text = json_text(data.path), json_text(data.lines)
  if not path or not text then
    return nil, nil
  end
  local spans = {}
  for _, sub in ipairs(data.submatches or {}) do
    spans[#spans + 1] = {
      start = sub.start,
      stop = sub["end"],
      rep = sub.replacement and json_text(sub.replacement) or nil,
    }
  end
  return relative(path),
    {
      lnum = data.line_number,
      text = (text:gsub("\r?\n$", "")),
      spans = spans,
    }
end

---@param text string
---@param i integer  1-based byte index, may be out of range
---@return boolean
local function is_word_byte(text, i)
  local c = text:sub(i, i)
  return c ~= "" and c:match("[%w_]") ~= nil
end

--- Find the spans of `git grep -o`'s matches in their line.
---
--- The matches arrive in order and never overlap, so each is the first
--- occurrence of its text at or after the end of the previous one -- except
--- in whole-word mode, where an occurrence inside a longer word is skipped
--- just as git skipped it.
---@param text string      the line
---@param matches string[] the matched texts, in order
---@param word boolean
---@return gitvim.grep.Span[]
function M.locate(text, matches, word)
  local spans, from = {}, 1
  for _, m in ipairs(matches) do
    local s = text:find(m, from, true)
    while s and word and (is_word_byte(text, s - 1) or is_word_byte(text, s + #m)) do
      s = text:find(m, s + 1, true)
    end
    if not s then
      break -- the line changed under us; what was found is still right
    end
    spans[#spans + 1] = { start = s - 1, stop = s - 1 + #m }
    from = s + math.max(#m, 1)
  end
  return spans
end

--- A result being filled in, capped at `max` matches.
---@param backend gitvim.grep.Backend
---@param max integer
local function collector(backend, max)
  ---@type gitvim.grep.Result
  local result = { backend = backend, files = {}, count = 0, truncated = false }
  local index = {} ---@type table<string, gitvim.grep.File>

  --- Add a line. Returns true once a match past the cap arrives: stopping
  --- at exactly the cap could not tell "that was all" from "there is more".
  ---@param path string
  ---@param line gitvim.grep.Line
  ---@return boolean full
  local function add(path, line)
    if #line.spans == 0 then
      return false
    end
    local room = max - result.count
    if room <= 0 then
      result.truncated = true
      return true
    end
    if #line.spans > room then
      line.spans = vim.list_slice(line.spans, 1, room)
      result.truncated = true
    end
    local file = index[path]
    if not file then
      file = { path = path, lines = {}, count = 0 }
      index[path] = file
      result.files[#result.files + 1] = file
    end
    file.lines[#file.lines + 1] = line
    file.count = file.count + #line.spans
    result.count = result.count + #line.spans
    return result.truncated
  end

  return result, add
end

--- Feed a stream's chunks through a line splitter.
---@param on_line fun(line: string): boolean?  return true to stop
---@return fun(chunk: string): boolean stop, fun(): string rest
local function splitter(on_line)
  local buf = ""
  return function(chunk)
    buf = buf .. chunk
    local pos = 1
    while true do
      local nl = buf:find("\n", pos, true)
      if not nl then
        break
      end
      local stop = on_line(buf:sub(pos, nl - 1))
      pos = nl + 1
      if stop then
        buf = ""
        return true
      end
    end
    buf = buf:sub(pos)
    return false
  end, function()
    return buf
  end
end

---@param cmd string[]
---@param err gitvim.git.Error
---@return gitvim.git.Error
local function with_message(cmd, err)
  err.message = ("%s: %s"):format(cmd[1] == "rg" and "rg" or "git grep", err.message)
  return err
end

---@param root string
---@param q gitvim.grep.Query
---@param max integer
---@param cb fun(err?: gitvim.git.Error, res?: gitvim.grep.Result)
---@return gitvim.git.Stream
local function run_rg(root, q, max, cb)
  local result, add = collector("rg", max)
  local stream
  local cmd = M.rg_args(q)
  local done = false

  local feed = splitter(function(json)
    local path, line = M.parse_rg(json)
    return path ~= nil and add(path, line)
  end)

  stream = cli.stream_exec(cmd, { cwd = root }, function(chunk)
    if not done and feed(chunk) then
      done = true
      stream.kill() -- drops the exit callback, so finish here
      cb(nil, result)
    end
  end, function(err)
    done = true
    -- 1 is "no matches"; 2 with results is a file that could not be read,
    -- which should not throw away everything that could.
    if err and not (err.code == 1 or (err.code == 2 and result.count > 0)) then
      cb(with_message(cmd, err), nil)
      return
    end
    cb(nil, result)
  end)
  return stream
end

---@param root string
---@param q gitvim.grep.Query
---@param max integer
---@param cb fun(err?: gitvim.git.Error, res?: gitvim.grep.Result)
---@param flavor? "-P"|"-E"
---@return gitvim.git.Stream
local function run_git(root, q, max, cb, flavor)
  local result, add = collector("git", max)
  local args = M.git_args(q, flavor)
  local done = false
  local count = 0

  -- `-o` records for the file being read: lnum -> matched texts. A file's
  -- text is read once all of its records are in, which is when the path
  -- changes (git reports each file contiguously) or the stream ends.
  local current, pending, order = nil, {}, {}

  local function flush()
    if not current then
      return false
    end
    local path = current
    current = nil
    local ok, lines = pcall(vim.fn.readfile, root .. "/" .. path)
    if not ok then
      lines = {}
    end
    for _, lnum in ipairs(order) do
      local text = (lines[lnum] or ""):gsub("\r$", "")
      if add(path, { lnum = lnum, text = text, spans = M.locate(text, pending[lnum], q.word) }) then
        return true
      end
    end
    return false
  end

  -- Records are `path NUL lnum NUL match LF`; a path may itself hold a
  -- newline, so the NULs are found first.
  local buf = ""
  local function feed(chunk)
    buf = buf .. chunk
    local pos = 1
    while true do
      local z1 = buf:find("\0", pos, true)
      local z2 = z1 and buf:find("\0", z1 + 1, true)
      local nl = z2 and buf:find("\n", z2 + 1, true)
      if not nl then
        break
      end
      local path = buf:sub(pos, z1 - 1)
      local lnum = tonumber(buf:sub(z1 + 1, z2 - 1))
      local text = buf:sub(z2 + 1, nl - 1)
      pos = nl + 1

      if path ~= current then
        if flush() then
          return true
        end
        current, pending, order = path, {}, {}
      end
      if lnum then
        if not pending[lnum] then
          pending[lnum] = {}
          order[#order + 1] = lnum
        end
        table.insert(pending[lnum], text)
        count = count + 1
        -- One record past the cap is enough to know the result is truncated.
        if count > max then
          buf = ""
          return true
        end
      end
    end
    buf = buf:sub(pos)
    return false
  end

  local stream
  stream = cli.stream(args, { cwd = root }, function(chunk)
    if not done and feed(chunk) then
      done = true
      stream.kill()
      flush()
      result.truncated = result.truncated or count > max
      cb(nil, result)
    end
  end, function(err)
    done = true
    if err and err.code ~= 1 then
      -- PCRE is a build option; fall back to extended regexps without it.
      local msg = err.stderr:lower()
      if flavor == nil and q.regex and (msg:find("pcre") or msg:find("not supported")) then
        stream = run_git(root, q, max, cb, "-E")
        return
      end
      cb(with_message({ "git" }, err), nil)
      return
    end
    flush()
    cb(nil, result)
  end)

  return {
    pause = function() end,
    resume = function() end,
    kill = function()
      stream.kill()
    end,
  }
end

--- Search `root` for `q`.
---
--- The callback runs once, on the main loop -- unless the search is
--- cancelled first, in which case it never runs at all.
---@param root string
---@param q gitvim.grep.Query
---@param opts? { backend?: gitvim.grep.Backend }
---@param cb fun(err?: gitvim.git.Error, res?: gitvim.grep.Result)
---@return gitvim.grep.Handle
function M.run(root, q, opts, cb)
  opts = opts or {}
  local max = q.max or require("gitvim.config").options.search.max_results
  local backend = opts.backend or M.backend()
  local cancelled = false

  if q.pattern == "" then
    vim.schedule(function()
      if not cancelled then
        cb(nil, { backend = backend, files = {}, count = 0, truncated = false })
      end
    end)
    return {
      cancel = function()
        cancelled = true
      end,
    }
  end

  local function finish(err, res)
    if not cancelled then
      cancelled = true -- once only
      cb(err, res)
    end
  end

  local run = backend == "rg" and run_rg or run_git
  local stream = run(root, q, max, finish)
  return {
    cancel = function()
      cancelled = true
      stream.kill()
    end,
  }
end

--- A line with its matches replaced.
---
--- Each span's own expansion wins when ripgrep supplied one (regex mode,
--- where `$1` means something); otherwise `replace` is inserted verbatim.
---@param line gitvim.grep.Line
---@param replace string
---@return string
function M.substitute(line, replace)
  local out, pos = {}, 1
  for _, span in ipairs(line.spans) do
    out[#out + 1] = line.text:sub(pos, span.start)
    out[#out + 1] = span.rep or replace
    pos = span.stop + 1
  end
  out[#out + 1] = line.text:sub(pos)
  return table.concat(out)
end

return M
