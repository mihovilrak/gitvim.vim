--- The single place gitvim spawns git.
---
--- Every call goes through `run()`, which is asynchronous and invokes its
--- callback on the main loop, so callers may touch the editor API directly.
--- Output read a page at a time goes through `stream()` instead.
--- Non-zero exits become a structured `gitvim.git.Error` rather than a string,
--- so the UI can branch on `err.kind` instead of matching stderr itself.

local M = {}

--- Flags applied to every invocation.
---   --no-optional-locks   never take .git/index.lock: gitvim polls status in the
---                         background and must not race the user's own shell git
---   core.quotepath=false  paths arrive as raw UTF-8 bytes rather than \303\274
local BASE = { "git", "--no-optional-locks", "-c", "core.quotepath=false" }

--- Seconds before a call is killed. Generous: fetch/pull are on this path too.
local DEFAULT_TIMEOUT = 30000

---@class gitvim.git.Result
---@field stdout string
---@field stderr string
---@field code integer
---@field signal integer

---@alias gitvim.git.ErrorKind
---| "not_a_repo"   # cwd is outside any work tree
---| "bad_revision" # the rev does not resolve
---| "bad_path"     # the pathspec matches nothing
---| "permission"   # the filesystem said no
---| "auth"         # the remote said no
---| "network"      # the remote was unreachable
---| "locked"       # another git holds the index lock
---| "conflict"     # the operation needs a clean merge state
---| "killed"       # timed out or signalled
---| "spawn"        # git could not be executed at all
---| "empty_message" # a commit was asked for with nothing to say
---| "no_remote"    # a push needs a remote and there is none
---| "detached"     # the operation needs a branch and HEAD is detached
---| "unknown"      # non-zero exit we have no pattern for

---@class gitvim.git.Error
---@field kind gitvim.git.ErrorKind
---@field message string  one-line, prefix-stripped, safe for vim.notify
---@field code integer
---@field signal integer
---@field stderr string
---@field args string[]
---@field cwd? string

---@class gitvim.git.Opts
---@field cwd? string
---@field stdin? string
---@field env? table<string, string>
---@field timeout? integer
---@field text? boolean  normalise CRLF in the output (default true); false keeps bytes exact

--- stderr patterns -> error kind, first match wins.
---
--- Order matters: the narrow remote-auth cases must be tested before the
--- generic "permission denied", which would otherwise swallow `(publickey)`.
---@type { kind: gitvim.git.ErrorKind, pat: string }[]
local PATTERNS = {
  { kind = "not_a_repo", pat = "not a git repository" },
  { kind = "not_a_repo", pat = "this operation must be run in a work tree" },
  { kind = "auth", pat = "permission denied %(publickey" },
  { kind = "auth", pat = "authentication failed" },
  { kind = "auth", pat = "could not read username" },
  { kind = "auth", pat = "could not read password" },
  { kind = "auth", pat = "invalid username or password" },
  { kind = "network", pat = "could not resolve host" },
  { kind = "network", pat = "connection timed out" },
  { kind = "network", pat = "connection refused" },
  { kind = "network", pat = "unable to access" },
  { kind = "locked", pat = "index%.lock" },
  { kind = "locked", pat = "unable to create.*%.lock" },
  { kind = "conflict", pat = "you have unmerged files" },
  { kind = "conflict", pat = "fix conflicts" },
  { kind = "conflict", pat = "you need to resolve your current index first" },
  { kind = "conflict", pat = "would be overwritten by" },
  { kind = "bad_revision", pat = "unknown revision or path not in the working tree" },
  { kind = "bad_revision", pat = "bad revision" },
  -- `rev-parse --verify` reports an unresolvable ref this way, with no mention
  -- of the ref itself.
  { kind = "bad_revision", pat = "needed a single revision" },
  { kind = "bad_revision", pat = "not a valid object name" },
  { kind = "bad_revision", pat = "ambiguous argument" },
  { kind = "bad_path", pat = "did not match any file" },
  { kind = "bad_path", pat = "pathspec .* did not match" },
  { kind = "bad_path", pat = "no such file or directory" },
  { kind = "permission", pat = "permission denied" },
  { kind = "permission", pat = "operation not permitted" },
}

--- Classify a failed invocation.
---
--- Exposed so the mapping can be unit tested against synthetic stderr without
--- having to provoke every failure for real.
---@param code integer
---@param stderr string
---@param signal? integer
---@return gitvim.git.ErrorKind
function M.classify(code, stderr, signal)
  if signal and signal ~= 0 then
    return "killed"
  end
  local lower = (stderr or ""):lower()
  for _, entry in ipairs(PATTERNS) do
    if lower:find(entry.pat) then
      return entry.kind
    end
  end
  -- 128 is git's "fatal" catch-all; without a pattern we still know nothing more.
  local _ = code
  return "unknown"
end

--- Reduce stderr to a single line fit for `vim.notify`.
---@param stderr string
---@return string
local function message_of(stderr)
  for _, line in ipairs(vim.split(stderr or "", "\n", { plain = true })) do
    line = vim.trim(line)
    if line ~= "" then
      -- Strip git's own severity prefix; the error carries `kind` instead.
      return (line:gsub("^fatal:%s*", ""):gsub("^error:%s*", ""))
    end
  end
  return "git exited non-zero"
end

---@param args string[]
---@param opts gitvim.git.Opts
---@param res gitvim.git.Result
---@return gitvim.git.Error
local function build_error(args, opts, res)
  return {
    kind = M.classify(res.code, res.stderr, res.signal),
    message = message_of(res.stderr),
    code = res.code,
    signal = res.signal or 0,
    stderr = res.stderr or "",
    args = args,
    cwd = opts.cwd,
  }
end

---@param args string[]
---@return string[]
local function command(args)
  local cmd = vim.list_extend({}, BASE)
  return vim.list_extend(cmd, args)
end

---@param out vim.SystemCompleted
---@return gitvim.git.Result
local function normalize(out)
  return {
    stdout = out.stdout or "",
    stderr = out.stderr or "",
    code = out.code or 0,
    signal = out.signal or 0,
  }
end

--- Run git asynchronously.
---
--- The callback always runs on the main loop, never in a fast-event context,
--- so it is free to call any editor API.
---@param args string[]           git arguments, without the leading "git"
---@param opts? gitvim.git.Opts
---@param cb fun(err?: gitvim.git.Error, res?: gitvim.git.Result)
function M.run(args, opts, cb)
  opts = opts or {}
  vim.validate("args", args, "table")
  vim.validate("cb", cb, "callable")

  local function finish(err, res)
    vim.schedule(function()
      cb(err, res)
    end)
  end

  local ok, err = pcall(vim.system, command(args), {
    cwd = opts.cwd,
    stdin = opts.stdin,
    env = opts.env,
    timeout = opts.timeout or DEFAULT_TIMEOUT,
    text = opts.text ~= false,
  }, function(out)
    local res = normalize(out)
    if res.code ~= 0 then
      finish(build_error(args, opts, res), res)
    else
      finish(nil, res)
    end
  end)

  -- A missing git binary or an unreadable cwd throws rather than exiting non-zero.
  if not ok then
    finish({
      kind = "spawn",
      message = tostring(err),
      code = -1,
      signal = 0,
      stderr = tostring(err),
      args = args,
      cwd = opts.cwd,
    }, nil)
  end
end

---@class gitvim.git.Stream
---@field pause fun()   stop reading stdout; git blocks once the pipe fills
---@field resume fun()
---@field kill fun()    end git and drop every callback still to come

--- Run git and hand its stdout over as it arrives, for output too long to
--- wait for. Reading can be paused, and a paused git costs nothing: it
--- blocks on the full pipe until reading resumes. There is no timeout, so the
--- caller owns the process and must `kill` it once done with it.
---
--- Both callbacks run on the main loop, in order: every chunk, then `on_exit`
--- once git has exited and its output is drained.
---@param args string[]  git arguments, without the leading "git"
---@param opts? { cwd?: string }
---@param on_stdout fun(chunk: string)
---@param on_exit fun(err?: gitvim.git.Error)
---@return gitvim.git.Stream
function M.stream(args, opts, on_stdout, on_exit)
  opts = opts or {}
  local uv = vim.uv
  local cmd = command(args)
  local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
  local errs = {}
  local killed, exited, reading = false, false, false
  local open = 2 -- pipes not yet at EOF
  local code, signal = 0, 0
  local handle, spawn_err

  local function finish()
    if exited and open == 0 then
      vim.schedule(function()
        if killed then
          return
        end
        killed = true
        local res = { stdout = "", stderr = table.concat(errs), code = code, signal = signal }
        on_exit(code ~= 0 and build_error(args, opts, res) or nil)
      end)
    end
  end

  ---@param pipe uv.uv_pipe_t
  ---@param on_data fun(data: string)
  local function reader(pipe, on_data)
    return function(err, data)
      if data then
        on_data(data)
        return
      end
      -- EOF, or a read error, which ends the output all the same.
      local _ = err
      if not pipe:is_closing() then
        pipe:close()
      end
      open = open - 1
      finish()
    end
  end

  local read_stdout = reader(stdout, function(data)
    vim.schedule(function()
      if not killed then
        on_stdout(data)
      end
    end)
  end)

  handle, spawn_err = uv.spawn(cmd[1], {
    args = vim.list_slice(cmd, 2),
    cwd = opts.cwd,
    stdio = { nil, stdout, stderr },
    hide = true,
  }, function(c, s)
    code, signal = c, s
    exited = true
    handle:close()
    finish()
  end)

  local stream = {}
  function stream.pause()
    if reading and not stdout:is_closing() then
      stdout:read_stop()
      reading = false
    end
  end
  function stream.resume()
    if not reading and not stdout:is_closing() then
      stdout:read_start(read_stdout)
      reading = true
    end
  end
  function stream.kill()
    if killed then
      return
    end
    killed = true
    if not exited and handle and not handle:is_closing() then
      handle:kill("sigterm")
    end
    for _, pipe in ipairs({ stdout, stderr }) do
      if not pipe:is_closing() then
        pipe:close()
      end
    end
  end

  if not handle then
    for _, pipe in ipairs({ stdout, stderr }) do
      pipe:close()
    end
    killed = true
    vim.schedule(function()
      on_exit({
        kind = "spawn",
        message = tostring(spawn_err),
        code = -1,
        signal = 0,
        stderr = tostring(spawn_err),
        args = args,
        cwd = opts.cwd,
      })
    end)
    return stream
  end

  stderr:read_start(reader(stderr, function(data)
    errs[#errs + 1] = data
  end))
  stream.resume()
  return stream
end

--- Blocking variant. Tests and `:checkhealth` only.
---
--- Guarded rather than merely documented: it refuses to run once a UI is
--- attached, so it cannot quietly creep into a render path and stall the editor.
--- Pass `force = true` to override (health check does, deliberately).
---@param args string[]
---@param opts? gitvim.git.Opts | { force?: boolean }
---@return gitvim.git.Error? err
---@return gitvim.git.Result? res
function M.sync(args, opts)
  opts = opts or {}
  if not opts.force and #vim.api.nvim_list_uis() > 0 then
    error("gitvim.git.cli.sync() is blocking and must not be called with a UI attached", 2)
  end

  local ok, out = pcall(function()
    return vim
      .system(command(args), {
        cwd = opts.cwd,
        stdin = opts.stdin,
        env = opts.env,
        timeout = opts.timeout or DEFAULT_TIMEOUT,
        text = opts.text ~= false,
      })
      :wait()
  end)

  if not ok then
    return {
      kind = "spawn",
      message = tostring(out),
      code = -1,
      signal = 0,
      stderr = tostring(out),
      args = args,
      cwd = opts.cwd,
    },
      nil
  end

  local res = normalize(out)
  if res.code ~= 0 then
    return build_error(args, opts, res), res
  end
  return nil, res
end

--- Split NUL-delimited output, dropping the trailing empty field.
---
--- Every gitvim git call that can carry a path uses `-z`, because git otherwise
--- quote-escapes anything with a space or a non-ASCII byte.
---@param s string
---@return string[]
function M.split_nul(s)
  local fields = vim.split(s or "", "\0", { plain = true })
  if fields[#fields] == "" then
    table.remove(fields)
  end
  return fields
end

--- Format an error the way the user should see it.
---@param err gitvim.git.Error
---@return string
function M.format_error(err)
  return ("gitvim: git %s: %s"):format(table.concat(err.args, " "), err.message)
end

return M
