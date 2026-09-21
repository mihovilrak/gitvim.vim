--- Commits, confirmed with `git log` run directly.

local commit = require("gitvim.git.commit")
local fixture = require("fixture")
local helpers = require("helpers")

local await = helpers.await

describe("git.commit", function()
  local fix

  before_each(function()
    fix = fixture.build()
  end)

  after_each(function()
    fix:destroy()
  end)

  ---@param fmt string
  ---@return string
  local function head(fmt)
    return vim.trim(fix:git({ "log", "-1", "--format=" .. fmt }))
  end

  it("passes the message on stdin, byte for byte", function()
    local message = 'feat: it\'s "quoted" $HOME `id` \\n;\n\nbody line one\nbody ünicode'
    local before = fix:sha("HEAD")
    assert.is_nil(await(function(done)
      commit.commit(fix.root, message, {}, done)
    end))
    assert.equals(before, fix:sha("HEAD~1"))
    assert.equals(message, head("%B"))
    -- Only what was staged went in.
    assert.equals("staged.lua", vim.trim(fix:git({ "show", "--name-only", "--format=", "HEAD" })))
  end)

  it("strips comment lines the way git's editor flow does", function()
    assert.is_nil(await(function(done)
      commit.commit(fix.root, "subject\n# a comment\n\nbody\n", {}, done)
    end))
    assert.equals("subject\n\nbody", head("%B"))
  end)

  it("refuses an empty or all-comment message without running git", function()
    local before = fix:sha("HEAD")
    local err = await(function(done)
      commit.commit(fix.root, "\n# only a comment\n  \n", {}, done)
    end)
    assert.equals("empty_message", err.kind)
    assert.equals(before, fix:sha("HEAD"))
  end)

  it("amends HEAD instead of adding a commit", function()
    local parent = fix:sha("HEAD~1")
    assert.is_nil(await(function(done)
      commit.commit(fix.root, "reworded", { amend = true }, done)
    end))
    assert.equals(parent, fix:sha("HEAD~1"))
    assert.equals("reworded", head("%s"))
  end)

  it("adds a Signed-off-by trailer on request", function()
    assert.is_nil(await(function(done)
      commit.commit(fix.root, "signed", { signoff = true }, done)
    end))
    assert.is_truthy(head("%B"):match("Signed%-off%-by: gitvim test <test@example%.com>"))
  end)

  it("reports git's error when there is nothing to commit", function()
    fix:git({ "reset", "-q" })
    local before = fix:sha("HEAD")
    local err = await(function(done)
      commit.commit(fix.root, "nothing", {}, done)
    end)
    assert.is_table(err)
    assert.equals(before, fix:sha("HEAD"))
  end)

  it("reads HEAD's message for an amend", function()
    local message = await(function(done)
      commit.last_message(fix.root, done)
    end)
    assert.equals("merge branch 'feature'", message)
  end)
end)

describe("commit editor", function()
  local config = require("gitvim.config")
  local editor = require("gitvim.ui.commit")
  local repo_mod = require("gitvim.git.repo")
  local state = require("gitvim.state")

  local fix, repo, store, notify

  before_each(function()
    config.setup()
    state.reset()
    repo_mod.reset()
    fix = fixture.build()
    local err
    err, store = await(function(done)
      require("gitvim").refresh(fix.root, done)
    end)
    assert.is_nil(err)
    repo = repo_mod.get(store.root)
    notify = vim.notify
    vim.notify = function() end ---@diagnostic disable-line: duplicate-set-field
  end)

  after_each(function()
    editor.close()
    vim.cmd.stopinsert()
    vim.notify = notify
    fix:destroy()
  end)

  ---@param lines string[]
  local function type_lines(lines)
    vim.api.nvim_buf_set_lines(assert(editor.buf()), 0, -1, false, lines)
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = editor.buf() })
  end

  it("opens a gitcommit float and keeps the draft when closed", function()
    editor.open(repo)
    local buf = assert(editor.buf())
    assert.equals("gitcommit", vim.bo[buf].filetype)
    assert.equals(buf, vim.api.nvim_get_current_buf())
    assert.is_truthy(vim.api.nvim_win_get_config(0).relative ~= "")

    type_lines({ "wip: draft", "", "more" })
    editor.close()
    assert.is_nil(editor.buf())
    assert.equals("wip: draft\n\nmore", store.draft)

    editor.open(repo)
    assert.same(
      { "wip: draft", "", "more" },
      vim.api.nvim_buf_get_lines(assert(editor.buf()), 0, -1, false)
    )
  end)

  it("commits the buffer and clears the draft", function()
    local before = fix:sha("HEAD")
    editor.open(repo)
    type_lines({ "feat: from the editor", "", "body" })
    assert.is_nil(await(function(done)
      editor.submit(done)
    end))
    assert.equals(before, fix:sha("HEAD~1"))
    assert.equals(
      "feat: from the editor\n\nbody",
      vim.trim(fix:git({ "log", "-1", "--format=%B" }))
    )
    assert.equals("", store.draft)
    assert.is_nil(editor.buf())
    assert.is_nil(helpers.entry(store.status, "staged.lua", "staged"), "status was refreshed")
  end)

  it("keeps the editor open when git refuses", function()
    editor.open(repo)
    type_lines({ "# only a comment" })
    local err = await(function(done)
      editor.submit(done)
    end)
    assert.equals("empty_message", err.kind)
    assert.is_number(editor.buf())
  end)

  it("amends with HEAD's message and leaves the draft alone", function()
    store.draft = "unrelated draft"
    local parent = fix:sha("HEAD~1")
    editor.open(repo, { amend = true })
    assert.is_true(vim.wait(1000, function()
      return editor.buf() ~= nil
    end, 10))
    assert.same(
      { "merge branch 'feature'" },
      vim.api.nvim_buf_get_lines(assert(editor.buf()), 0, -1, false)
    )
    type_lines({ "merge branch 'feature' (reworded)" })
    assert.is_nil(await(function(done)
      editor.submit(done)
    end))
    assert.equals(parent, fix:sha("HEAD~1"))
    assert.equals(
      "merge branch 'feature' (reworded)",
      vim.trim(fix:git({ "log", "-1", "--format=%s" }))
    )
    assert.equals("unrelated draft", store.draft)
  end)
end)
