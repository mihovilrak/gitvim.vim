-- Minimal init for headless test runs.
--   nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"
--
-- Dependencies are cloned into .tests/site on first run (gitignored).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local deps = root .. "/.tests/site/pack/deps/start"

---@param url string
---@param name string
local function ensure(url, name)
  local path = deps .. "/" .. name
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(deps, "p")
    print("gitvim tests: cloning " .. name .. " ...")
    vim.fn.system({ "git", "clone", "--filter=blob:none", "--depth=1", url, path })
    if vim.v.shell_error ~= 0 then
      error("failed to clone " .. url)
    end
  end
  vim.opt.runtimepath:append(path)
end

vim.opt.runtimepath:append(root)

-- So specs can `require("fixture")`. A searcher rather than a `package.path`
-- prepend: Neovim rebuilds package.path from 'runtimepath', so any entry added
-- here would be dropped again by the 'packpath' assignment further down.
table.insert(package.loaders, 2, function(name)
  local file = root .. "/tests/" .. name:gsub("%.", "/") .. ".lua"
  if vim.uv.fs_stat(file) then
    return loadfile(file)
  end
  return "\n\tno file '" .. file .. "'"
end)

ensure("https://github.com/nvim-lua/plenary.nvim", "plenary.nvim")
ensure("https://github.com/lewis6991/gitsigns.nvim", "gitsigns.nvim")

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.packpath = { deps }

-- Keep test runs independent of the developer's own git config.
local devnull = vim.fn.has("win32") == 1 and "NUL" or "/dev/null"
vim.env.GIT_CONFIG_GLOBAL = devnull
vim.env.GIT_CONFIG_SYSTEM = devnull
vim.env.GIT_AUTHOR_NAME = "gitvim test"
vim.env.GIT_AUTHOR_EMAIL = "test@example.com"
vim.env.GIT_COMMITTER_NAME = "gitvim test"
vim.env.GIT_COMMITTER_EMAIL = "test@example.com"

-- We run with --noplugin (to keep the developer's own config out of the way),
-- so plenary's plugin file must be sourced explicitly or :PlenaryBusted* is missing.
vim.cmd("runtime plugin/plenary.vim")

require("plenary.busted")
