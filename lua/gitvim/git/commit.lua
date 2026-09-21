--- Create commits.
---
--- The message always travels on stdin (`-F -`), never on the command line:
--- there is no quoting to get wrong, and a message may hold any byte.

local cli = require("gitvim.git.cli")

local M = {}

---@class gitvim.commit.Opts
---@field amend? boolean    rewrite HEAD instead of adding a commit
---@field signoff? boolean  append a Signed-off-by trailer

--- The argument list for a commit. Exposed for the specs.
---@param opts? gitvim.commit.Opts
---@return string[]
function M.args(opts)
  opts = opts or {}
  local args = { "commit", "--cleanup=strip", "-F", "-" }
  if opts.amend then
    args[#args + 1] = "--amend"
  end
  if opts.signoff then
    args[#args + 1] = "--signoff"
  end
  return args
end

--- Drop `#` comment lines and surrounding blank lines, the way git's
--- `--cleanup=strip` will, so an all-comment message counts as empty.
---@param message string
---@return string
function M.clean(message)
  local lines = {}
  for _, line in ipairs(vim.split(message or "", "\n", { plain = true })) do
    if not line:match("^#") then
      lines[#lines + 1] = line
    end
  end
  return vim.trim(table.concat(lines, "\n"))
end

--- Commit what is staged.
---@param root string
---@param message string
---@param opts? gitvim.commit.Opts
---@param cb fun(err?: gitvim.git.Error)
function M.commit(root, message, opts, cb)
  if M.clean(message) == "" then
    vim.schedule(function()
      cb({
        kind = "empty_message",
        message = "aborting commit due to empty commit message",
        code = 1,
        signal = 0,
        stderr = "",
        args = M.args(opts),
        cwd = root,
      })
    end)
    return
  end
  cli.run(M.args(opts), { cwd = root, stdin = message }, function(err)
    cb(err)
  end)
end

--- HEAD's full message, for prefilling an amend. Empty on an unborn branch.
---@param root string
---@param cb fun(message: string)
function M.last_message(root, cb)
  cli.run({ "log", "-1", "--format=%B" }, { cwd = root }, function(err, res)
    cb(err and "" or vim.trim(res.stdout))
  end)
end

return M
