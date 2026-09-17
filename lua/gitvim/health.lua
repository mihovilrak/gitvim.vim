--- :checkhealth gitvim

local M = {}

local MIN_GIT = { 2, 30, 0 }

---@return integer[]?
local function git_version()
  local res = vim.system({ "git", "--version" }, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  local major, minor, patch = (res.stdout or ""):match("(%d+)%.(%d+)%.?(%d*)")
  if not major then
    return nil
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

function M.check()
  vim.health.start("gitvim")

  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.11+ is required")
  end

  local ver = git_version()
  if not ver then
    vim.health.error("git executable not found in $PATH")
  elseif gte(ver, MIN_GIT) then
    vim.health.ok(("git %d.%d.%d"):format(ver[1], ver[2], ver[3]))
  else
    vim.health.warn(
      ("git %d.%d.%d is older than the supported %d.%d.%d"):format(
        ver[1],
        ver[2],
        ver[3],
        MIN_GIT[1],
        MIN_GIT[2],
        MIN_GIT[3]
      )
    )
  end

  -- Required: gitvim delegates the whole in-buffer layer to gitsigns (Plan.md D1).
  if pcall(require, "gitsigns") then
    vim.health.ok("gitsigns.nvim found")
  else
    vim.health.error("gitsigns.nvim not found", {
      "gitvim requires gitsigns for signs, blame and hunk staging.",
      "Install lewis6991/gitsigns.nvim.",
    })
  end

  -- Optional niceties.
  for name, what in pairs({
    ["snacks"] = "snacks.nvim (sidebar window)",
    ["mini.icons"] = "mini.icons (filetype icons)",
  }) do
    if pcall(require, name) then
      vim.health.ok(what .. " found")
    else
      vim.health.warn(what .. " not found; a fallback is used")
    end
  end

  if vim.o.mouse == "" then
    vim.health.warn("'mouse' is empty: click interactions are unavailable", {
      "All actions also have keymaps; set `vim.o.mouse = 'a'` for the VS Code feel.",
    })
  else
    vim.health.ok("'mouse' = " .. vim.o.mouse)
  end

  local res = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait()
  if res.code == 0 then
    vim.health.ok("git repository: " .. vim.trim(res.stdout or ""))
  else
    vim.health.info("cwd is not inside a git repository")
  end
end

return M
