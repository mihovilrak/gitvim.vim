--- health.lua: :checkhealth gitvim reports every dependency and misconfiguration.

local bridge = require("gitvim.buffer.bridge")
local config = require("gitvim.config")
local grep = require("gitvim.git.grep")
local health = require("gitvim.health")

--- Run the check with vim.health stubbed; return every reported line as
--- "level: message".
---@return string[]
local function run()
  local lines = {}
  local saved = {}
  for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
    saved[level] = vim.health[level]
    vim.health[level] = function(msg)
      lines[#lines + 1] = level .. ": " .. msg
    end
  end
  local ok, err = pcall(health.check)
  for level, fn in pairs(saved) do
    vim.health[level] = fn
  end
  assert(ok, err)
  return lines
end

---@param lines string[]
---@param pattern string
---@return string?
local function find(lines, pattern)
  for _, line in ipairs(lines) do
    if line:find(pattern) then
      return line
    end
  end
end

describe("health", function()
  local cwd, had_nerd_font

  before_each(function()
    cwd = vim.uv.cwd()
    had_nerd_font = vim.g.have_nerd_font
    config.setup({})
  end)

  after_each(function()
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.g.have_nerd_font = had_nerd_font
    bridge._set_adapter(nil)
    grep.force = nil
    config.setup({})
  end)

  it("names every gitsigns function the bridge calls", function()
    local source = table.concat(
      vim.fn.readfile(vim.api.nvim_get_runtime_file("lua/gitvim/buffer/bridge.lua", false)[1]),
      "\n"
    )
    local called = {}
    for name in source:gmatch('call%("([%w_]+)"') do
      called[name] = true
    end
    for _, name in ipairs(bridge.api) do
      assert.is_true(called[name] ~= nil, name .. " is listed but never called")
      called[name] = nil
    end
    assert.same({}, called)
  end)

  it("passes against the real gitsigns and git", function()
    local lines = run()
    assert.is_truthy(find(lines, "^ok: gitsigns.nvim found, with every function"))
    assert.is_truthy(find(lines, "^ok: git %d+%.%d+"))
    assert.is_nil(find(lines, "^error:"), table.concat(lines, "\n"))
  end)

  it("errors when gitsigns is missing or incomplete", function()
    bridge._set_adapter(false)
    assert.is_truthy(find(run(), "^error: gitsigns.nvim not found"))

    bridge._set_adapter({ setup = function() end })
    local line = find(run(), "^error: gitsigns.nvim lacks: ")
    assert.is_truthy(line)
    assert.is_truthy(line:find("stage_hunk", 1, true))
    assert.is_nil(line:find("setup", 1, true))
  end)

  it("explains the git grep fallback", function()
    grep.force = "git"
    assert.is_truthy(find(run(), "^warn: ripgrep not found"))
    grep.force = "rg"
    assert.is_truthy(find(run(), "^ok: ripgrep found"))
  end)

  it("flags a nerd style against a font that has no glyphs", function()
    config.setup({ icons = { style = "nerd" } })
    vim.g.have_nerd_font = false
    assert.is_truthy(find(run(), "^warn: icons.style = 'nerd'"))

    config.setup({ icons = { style = "auto" } })
    vim.g.have_nerd_font = nil
    assert.is_truthy(find(run(), "^info: icons.style = 'auto' and vim.g.have_nerd_font is unset"))
  end)

  it("warns when the gutter is clickable but the mouse is off", function()
    local mouse = vim.o.mouse
    vim.o.mouse = ""
    local lines = run()
    vim.o.mouse = mouse
    assert.is_truthy(find(lines, "^warn: 'mouse' is empty"))
    assert.is_truthy(find(lines, "^warn: buffer.clickable_gutter is on"))
  end)

  it("lists buffer keymaps that yield to global ones", function()
    vim.keymap.set("n", "<leader>gs", "<Nop>", { desc = "someone else" })
    local line = find(run(), "^warn: 1 buffer keymap%(s%) yield")
    vim.keymap.del("n", "<leader>gs")
    assert.is_truthy(line)
    assert.is_truthy(line:find("<leader>gs (someone else)", 1, true))
    assert.is_truthy(find(run(), "^ok: keymaps under <leader>g: no collisions"))
  end)

  it("reports the repository and a missing commit identity", function()
    local fixture = require("fixture").build()
    vim.cmd.cd(vim.fn.fnameescape(fixture.root))
    local lines = run()
    assert.is_truthy(find(lines, "^ok: worktree: "))
    assert.is_truthy(find(lines, "^info: HEAD:     main"))

    -- The test env sets identity through GIT_AUTHOR_*/GIT_COMMITTER_*, which
    -- `git config` cannot see, so the fixture has none configured.
    local identity = find(lines, "commit identity configured")
      or find(lines, "unset: commits will fail")
    assert.is_truthy(identity)

    vim.system({ "git", "config", "user.name", "Test" }, { cwd = fixture.root }):wait()
    vim.system({ "git", "config", "user.email", "t@example.com" }, { cwd = fixture.root }):wait()
    assert.is_truthy(find(run(), "^ok: commit identity configured"))
    fixture:destroy()
  end)

  it("says so outside a repository", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    assert.is_truthy(find(run(), "^info: not inside a git repository"))
  end)
end)
