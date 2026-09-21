--- External git operations reach the store through the watcher.

local config = require("gitvim.config")
local fixture = require("fixture")
local helpers = require("helpers")
local repo_mod = require("gitvim.git.repo")
local sidebar = require("gitvim.ui.sidebar")
local state = require("gitvim.state")
local watcher = require("gitvim.git.watcher")

local await = helpers.await

describe("git.watcher", function()
  local fix, store, is_open, open

  before_each(function()
    config.setup()
    state.reset()
    repo_mod.reset()
    fix = fixture.build()
    open = true
    is_open = sidebar.is_open
    sidebar.is_open = function() ---@diagnostic disable-line: duplicate-set-field
      return open
    end
    local err
    err, store = await(function(done)
      require("gitvim").refresh(fix.root, done)
    end)
    assert.is_nil(err)
    watcher.setup()
  end)

  after_each(function()
    watcher.stop()
    sidebar.is_open = is_open
    fix:destroy()
  end)

  ---@param path string
  ---@param group string
  ---@return boolean
  local function has(path, group)
    return helpers.entry(store.status, path, group) ~= nil
  end

  it("watches the active repository's git directory", function()
    assert.equals(repo_mod.active().gitdir, watcher.watching())
  end)

  it("picks up a stage made from a shell within a second", function()
    assert.is_true(has("modified.lua", "changes"))
    fix:git({ "add", "modified.lua" })
    assert.is_true(vim.wait(1000, function()
      return has("modified.lua", "staged") and not has("modified.lua", "changes")
    end, 10))
  end)

  it("picks up a commit made from a shell within a second", function()
    fix:git({ "commit", "-q", "-m", "external" })
    assert.is_true(vim.wait(1000, function()
      return not has("staged.lua", "staged")
    end, 10))
  end)

  it("only marks the store dirty while the sidebar is hidden", function()
    open = false
    local reads = 0
    local unsubscribe = state.subscribe("status", function()
      reads = reads + 1
    end)
    fix:git({ "add", "modified.lua" })
    assert.is_true(vim.wait(1000, function()
      return store:is_dirty("status")
    end, 10))
    vim.wait(200)
    unsubscribe()
    assert.equals(0, reads)
    assert.is_true(has("modified.lua", "changes"), "status was not re-read")
  end)

  it("debounces a burst of requests into one refresh", function()
    local reads = 0
    local unsubscribe = state.subscribe("status", function()
      reads = reads + 1
    end)
    watcher.stop() -- only the explicit requests below
    for _ = 1, 10 do
      watcher.request()
    end
    vim.wait(400)
    unsubscribe()
    assert.equals(1, reads)
  end)

  it("refreshes on BufWritePost", function()
    local path = fix.root .. "/modified.lua"
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 'written'" })
    fix:git({ "add", "modified.lua" })
    vim.cmd("silent write")
    assert.is_true(vim.wait(1000, function()
      return has("modified.lua", "staged") and has("modified.lua", "changes")
    end, 10))
    vim.cmd("bwipeout!")
  end)
end)
