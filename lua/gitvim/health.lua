--- :checkhealth gitvim

local cli = require("gitvim.git.cli")
local status = require("gitvim.git.status")

local M = {}

--- Oldest git gitvim is tested against. `--porcelain=v2` needs 2.11 and
--- `--absolute-git-dir` 2.13, so this floor is about the rest of the plan.
local MIN_GIT = { 2, 30, 0 }

--- Health runs on the main loop with a UI attached, which is exactly what
--- `cli.sync` refuses by default -- `force` is the documented opt-out, and
--- :checkhealth is the one place blocking on git is the right thing.
local FORCE = { force = true }

---@return integer[]? version, string? err
local function git_version()
  local err, res = cli.sync({ "--version" }, FORCE)
  if err then
    return nil, err.message
  end
  local major, minor, patch = (res.stdout or ""):match("(%d+)%.(%d+)%.?(%d*)")
  if not major then
    return nil, "could not parse: " .. vim.trim(res.stdout or "")
  end
  return { tonumber(major), tonumber(minor), tonumber(patch) or 0 }
end

---@param a integer[]
---@param b integer[]
---@return boolean
local function gte(a, b)
  for i = 1, 3 do
    if (a[i] or 0) ~= (b[i] or 0) then
      return (a[i] or 0) > (b[i] or 0)
    end
  end
  return true
end

local function check_editor()
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.11+ is required")
  end

  if vim.o.mouse == "" then
    vim.health.warn("'mouse' is empty: click interactions are unavailable", {
      "All actions also have keymaps (D5); set `vim.o.mouse = 'a'` for the VS Code feel.",
    })
  else
    vim.health.ok("'mouse' = " .. vim.o.mouse)
  end
end

local function check_git()
  local ver, err = git_version()
  if not ver then
    vim.health.error("git unusable: " .. (err or "unknown error"), {
      "gitvim shells out to git for everything; make sure it is in $PATH.",
    })
    return false
  end

  local pretty = ("git %d.%d.%d"):format(ver[1], ver[2], ver[3])
  if gte(ver, MIN_GIT) then
    vim.health.ok(pretty)
  else
    vim.health.warn(
      ("%s is older than the supported %d.%d.%d"):format(pretty, MIN_GIT[1], MIN_GIT[2], MIN_GIT[3])
    )
  end
  return true
end

local function check_plugins()
  -- Required: gitvim delegates the whole in-buffer layer to gitsigns (D1).
  if require("gitvim.buffer.bridge").available() then
    vim.health.ok("gitsigns.nvim found")
  else
    vim.health.error("gitsigns.nvim not found", {
      "gitvim requires gitsigns for signs, blame and hunk staging.",
      "Install lewis6991/gitsigns.nvim.",
    })
  end

  -- Optional niceties.
  for _, spec in ipairs({
    { "snacks", "snacks.nvim (pickers and notifications)" },
    { "mini.icons", "mini.icons (filetype icons)" },
  }) do
    if pcall(require, spec[1]) then
      vim.health.ok(spec[2] .. " found")
    else
      vim.health.warn(spec[2] .. " not found; a fallback is used")
    end
  end
end

--- Report the repository around the current buffer, the way gitvim will see it.
local function check_repo()
  local buf = vim.api.nvim_buf_get_name(0)
  local dir = buf ~= "" and vim.fs.dirname(buf) or vim.uv.cwd()

  local err, res = cli.sync(
    { "rev-parse", "--show-toplevel", "--absolute-git-dir" },
    { cwd = dir, force = true }
  )
  if err then
    if err.kind == "not_a_repo" then
      vim.health.info("not inside a git repository: " .. tostring(dir))
    else
      vim.health.error(cli.format_error(err))
    end
    return
  end

  local lines = vim.split(vim.trim(res.stdout), "\n", { plain = true })
  local root = vim.trim(lines[1] or "")
  if root == "" then
    vim.health.warn("bare repository: gitvim needs a work tree")
    return
  end

  vim.health.ok("worktree: " .. root)
  vim.health.info("gitdir:   " .. vim.trim(lines[2] or "?"))

  local serr, sres = cli.sync(status.args({ untracked = "no" }), { cwd = root, force = true })
  if serr then
    vim.health.error(cli.format_error(serr))
    return
  end

  local branch = status.parse(sres.stdout).branch
  vim.health.info(
    "HEAD:     " .. (branch.head or (branch.oid and branch.oid:sub(1, 7)) or "(no commits)")
  )
  if branch.upstream then
    vim.health.info(("upstream: %s (+%d/-%d)"):format(branch.upstream, branch.ahead, branch.behind))
  else
    vim.health.info("upstream: none")
  end
end

function M.check()
  vim.health.start("gitvim")
  check_editor()
  check_plugins()
  if check_git() then
    check_repo()
  end
end

return M
