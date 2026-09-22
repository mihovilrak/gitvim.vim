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

--- The directory :checkhealth was run from, as gitvim would resolve it.
---@return string
local function current_dir()
  local buf = vim.api.nvim_buf_get_name(0)
  if buf ~= "" and not buf:find("^health://") then
    return vim.fs.dirname(buf)
  end
  return vim.uv.cwd() or "."
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

local function check_gitsigns()
  local bridge = require("gitvim.buffer.bridge")
  if not bridge.available() then
    vim.health.error("gitsigns.nvim not found", {
      "gitvim requires gitsigns for signs, blame and hunk staging.",
      "Install lewis6991/gitsigns.nvim.",
    })
    return
  end
  local missing = bridge.missing()
  if #missing == 0 then
    vim.health.ok("gitsigns.nvim found, with every function gitvim calls")
  else
    vim.health.error("gitsigns.nvim lacks: " .. table.concat(missing, ", "), {
      "Update gitsigns.nvim; these in-buffer actions are no-ops until then.",
    })
  end
end

local function check_optional()
  -- gitvim only ever calls vim.ui.select, vim.ui.input and vim.notify;
  -- snacks is the usual provider of nicer ones in LazyVim.
  if pcall(require, "snacks") then
    vim.health.ok("snacks.nvim found (pickers, inputs and notifications)")
  else
    vim.health.info("snacks.nvim not found; the built-in vim.ui.select and vim.notify are used")
  end

  if pcall(require, "mini.icons") then
    vim.health.ok("mini.icons found (filetype icons)")
  elseif pcall(require, "nvim-web-devicons") then
    vim.health.ok("nvim-web-devicons found (filetype icons)")
  else
    vim.health.info("no icon provider (mini.icons or nvim-web-devicons); files get a generic icon")
  end

  if require("gitvim.git.grep").backend() == "rg" then
    vim.health.ok("ripgrep found (Search tab)")
  else
    vim.health.warn("ripgrep not found; Search falls back to `git grep`", {
      "`git grep` searches tracked files only and cannot expand $1 in regex replacements.",
      "Install ripgrep for the full Search tab.",
    })
  end
end

local function check_config()
  local ok, gitvim = pcall(require, "gitvim")
  if ok and gitvim._is_setup() then
    vim.health.ok("setup() has run")
  else
    vim.health.info("setup() has not run yet; the first :GitVim runs it with the defaults")
  end

  local opts = require("gitvim.config").options

  -- Icons: "auto" can only guess the font.
  local icons = opts.icons
  if not icons.enabled then
    vim.health.info("icons disabled: text stand-ins are used")
  elseif icons.style == "auto" then
    if vim.g.have_nerd_font == nil then
      vim.health.info(
        "icons.style = 'auto' and vim.g.have_nerd_font is unset: assuming a Nerd Font",
        {
          "If you see boxes or question marks, set `vim.g.have_nerd_font = false` or `icons.style = 'ascii'`.",
        }
      )
    else
      vim.health.ok(
        ("icons.style = 'auto' (vim.g.have_nerd_font = %s)"):format(tostring(vim.g.have_nerd_font))
      )
    end
  elseif icons.style == "nerd" and vim.g.have_nerd_font == false then
    vim.health.warn("icons.style = 'nerd' but vim.g.have_nerd_font = false", {
      "Use `icons.style = 'auto'` or 'ascii' if the font lacks Nerd Font glyphs.",
    })
  else
    vim.health.ok("icons.style = '" .. icons.style .. "'")
  end

  -- Clickable gutter.
  local buffer = opts.buffer
  if buffer.clickable_gutter then
    if vim.o.mouse == "" then
      vim.health.warn(
        "buffer.clickable_gutter is on but 'mouse' is empty: the gutter cannot be clicked"
      )
    else
      local sc = vim.go.statuscolumn
      if sc ~= "" and not vim.startswith(sc, "%!") and not sc:find("_GitVim%.") then
        vim.health.info("clickable gutter wraps your 'statuscolumn': " .. sc)
      else
        vim.health.ok("clickable gutter enabled")
      end
    end
  end
end

--- Report the default buffer keys another mapping shadows. Buffer maps yield
--- to global ones (see signs.map_buffer), so a collision is not an error, but
--- it is the usual reason "gitvim's <leader>gs does nothing".
local function check_keymaps()
  local opts = require("gitvim.config").options.keymaps
  if not opts.enabled then
    vim.health.info("default keymaps disabled")
    return
  end
  local function code(lhs)
    return vim.api.nvim_replace_termcodes(lhs, true, true, true)
  end
  local global = {}
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if not vim.startswith(map.desc or "", "gitvim: ") then
      global[code(map.lhs)] = map.desc or map.rhs or "(lua function)"
    end
  end

  local yielded = {}
  for _, suffix in ipairs(require("gitvim.buffer.signs").keys) do
    local lhs = opts.prefix .. suffix
    local owner = global[code(lhs)]
    if owner then
      yielded[#yielded + 1] = ("%s (%s)"):format(lhs, owner)
    end
  end

  if #yielded == 0 then
    vim.health.ok("keymaps under " .. opts.prefix .. ": no collisions")
  else
    vim.health.warn(
      ("%d buffer keymap(s) yield to existing global maps: %s"):format(
        #yielded,
        table.concat(yielded, ", ")
      ),
      { "Pick another `keymaps.prefix`, or map the gitvim actions yourself." }
    )
  end
  if global[code(opts.prefix)] then
    vim.health.warn(
      ("%s itself is mapped: every %s… key waits for 'timeoutlen'"):format(
        opts.prefix,
        opts.prefix
      )
    )
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

--- `git config <key>`, or nil when unset.
---@param key string
---@param cwd string
---@return string?
local function git_config(key, cwd)
  local err, res = cli.sync({ "config", "--get", key }, { cwd = cwd, force = true })
  local value = not err and vim.trim(res.stdout or "") or ""
  return value ~= "" and value or nil
end

--- Report the repository around the current buffer, the way gitvim will see it.
local function check_repo()
  local dir = current_dir()

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
    vim.health.info("upstream: none (push publishes the branch with --set-upstream)")
  end

  local unset = {}
  for _, key in ipairs({ "user.name", "user.email" }) do
    if not git_config(key, root) then
      unset[#unset + 1] = key
    end
  end
  if #unset == 0 then
    vim.health.ok("commit identity configured")
  else
    vim.health.warn(table.concat(unset, " and ") .. " unset: commits will fail", {
      'git config --global user.name "Your Name"',
      "git config --global user.email you@example.com",
    })
  end
end

function M.check()
  vim.health.start("gitvim: editor")
  check_editor()

  vim.health.start("gitvim: dependencies")
  check_gitsigns()
  check_optional()
  local git_ok = check_git()

  vim.health.start("gitvim: configuration")
  check_config()
  check_keymaps()

  if git_ok then
    vim.health.start("gitvim: repository")
    check_repo()
  end
end

return M
