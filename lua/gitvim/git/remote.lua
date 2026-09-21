--- Fetch, pull and push.
---
--- These are the slow calls, so each one says what it is doing through
--- `vim.notify` when it starts and again when it ends. Credentials are never
--- prompted for: a terminal prompt would hang a background process, so git is
--- told to fail instead and the error says why.

local cli = require("gitvim.git.cli")

local M = {}

--- Remote operations get far longer than the 30 s default.
local TIMEOUT = 5 * 60 * 1000

local ENV = { GIT_TERMINAL_PROMPT = "0" }

--- A stable id lets notifiers that support replacement (snacks, nvim-notify)
--- turn "Pushing..." into "Pushed" instead of stacking two messages.
local NOTIFY = { title = "gitvim", id = "gitvim_remote" }

---@param msg string
---@param level? integer
local function notify(msg, level)
  vim.notify("gitvim: " .. msg, level or vim.log.levels.INFO, NOTIFY)
end

---@param root string
---@param args string[]
---@param verb { doing: string, done: string }
---@param cb fun(err?: gitvim.git.Error)
local function run(root, args, verb, cb)
  notify(verb.doing .. "...")
  cli.run(args, { cwd = root, env = ENV, timeout = TIMEOUT }, function(err)
    if err then
      notify(cli.format_error(err):gsub("^gitvim: ", ""), vim.log.levels.ERROR)
    else
      notify(verb.done)
    end
    cb(err)
  end)
end

---@param kind gitvim.git.ErrorKind
---@param message string
---@param args string[]
---@param root string
---@return gitvim.git.Error
local function error_of(kind, message, args, root)
  return {
    kind = kind,
    message = message,
    code = 1,
    signal = 0,
    stderr = "",
    args = args,
    cwd = root,
  }
end

--- The remote a new upstream should point at: `origin` when there is one,
--- otherwise the only (or first) remote.
---@param root string
---@param cb fun(err?: gitvim.git.Error, name?: string)
function M.default_remote(root, cb)
  cli.run({ "remote" }, { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    local names = vim.split(vim.trim(res.stdout), "\n", { trimempty = true })
    if vim.tbl_contains(names, "origin") then
      return cb(nil, "origin")
    end
    if names[1] then
      return cb(nil, names[1])
    end
    cb(error_of("no_remote", "no remote configured", { "remote" }, root))
  end)
end

---@param root string
---@param cb fun(err?: gitvim.git.Error)
function M.fetch(root, cb)
  run(root, { "fetch", "--prune" }, { doing = "Fetching", done = "Fetched" }, cb)
end

---@param root string
---@param cb fun(err?: gitvim.git.Error)
function M.pull(root, cb)
  run(root, { "pull" }, { doing = "Pulling", done = "Pulled" }, cb)
end

--- Push the current branch, publishing it with `--set-upstream` when it has
--- no upstream yet (VS Code's "Publish Branch").
---@param repo gitvim.Repo
---@param cb fun(err?: gitvim.git.Error)
function M.push(repo, cb)
  if repo.upstream then
    run(repo.root, { "push" }, { doing = "Pushing", done = "Pushed" }, cb)
    return
  end

  if not repo.head then
    local err =
      error_of("detached", "HEAD is detached; check out a branch to push", { "push" }, repo.root)
    notify(err.message, vim.log.levels.ERROR)
    vim.schedule(function()
      cb(err)
    end)
    return
  end

  M.default_remote(repo.root, function(err, remote)
    if err then
      notify(err.message, vim.log.levels.ERROR)
      return cb(err)
    end
    run(repo.root, { "push", "--set-upstream", remote, repo.head }, {
      doing = ("Publishing %s to %s"):format(repo.head, remote),
      done = "Published " .. repo.head,
    }, cb)
  end)
end

return M
