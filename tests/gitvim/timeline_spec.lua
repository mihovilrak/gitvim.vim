--- The TIMELINE section, asserted as render rows against the fixture.

local config = require("gitvim.config")
local fixture = require("fixture")
local helpers = require("helpers")
local repo_mod = require("gitvim.git.repo")
local state = require("gitvim.state")
local timeline = require("gitvim.ui.sections.timeline")

local await = helpers.await

---@param row gitvim.render.Row
---@return string
local function text(row)
  local out = {}
  for i, chunk in ipairs(row) do
    out[i] = chunk.text or ""
  end
  return table.concat(out)
end

---@param rows gitvim.render.Row[]
---@param needle string  plain text
---@return gitvim.render.Row?
local function find(rows, needle)
  for _, row in ipairs(rows) do
    if text(row):find(needle, 1, true) then
      return row
    end
  end
end

--- The revision rows, rename rows excluded.
---@param rows gitvim.render.Row[]
---@return gitvim.render.Row[]
local function revisions(rows)
  return vim.tbl_filter(function(row)
    return row.data and row.data.type == "timeline_revision" and not row.data.rename
  end, rows)
end

describe("TIMELINE section", function()
  local fix, repo, store, ctx

  local function refresh_status()
    local err, result = await(function(done)
      require("gitvim.git.status").get(repo.root, nil, done)
    end)
    assert.is_nil(err)
    store:set_status(result)
  end

  --- Render until the history in flight has landed, then render once more.
  ---@return gitvim.render.Row[]
  local function settle()
    local ok = vim.wait(5000, function()
      timeline.rows(ctx)
      local h = store.timeline and store.timeline.history
      return h ~= nil and (h.loaded or h.error ~= nil) and not h.loading
    end, 10)
    assert.is_true(ok, "the history should have loaded")
    return timeline.rows(ctx)
  end

  ---@param opts? table  extra config
  local function setup(opts)
    config.setup(vim.tbl_deep_extend("force", { icons = { style = "ascii" } }, opts or {}))
  end

  --- Stub the review, run `fn`, and hand back the calls it made.
  ---@param fn fun()
  ---@return table[]
  local function reviews(fn)
    local review = require("gitvim.ui.review")
    local original = review.open
    local calls = {}
    review.open = function(...)
      calls[#calls + 1] = { ... }
    end
    local ok, err = pcall(fn)
    review.open = original
    assert.is_true(ok, err)
    return calls
  end

  before_each(function()
    setup()
    state.reset()
    repo_mod.reset()
    fix = fixture.build()
    local _, found = await(function(done)
      repo_mod.detect(fix.root, done)
    end)
    repo = found
    store = state.get(repo.root)
    ctx = { repo = repo, store = store, width = 70, focused = true }
    vim.cmd("silent! %bwipeout!")
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    timeline.close(store)
    fix:destroy()
    state.reset()
    repo_mod.reset()
    config.setup({})
  end)

  it("says so outside a repository", function()
    assert.is_not_nil(find(timeline.rows({ width = 40 }), "Not a git repository"))
  end)

  it("asks for a file when there is none", function()
    refresh_status()
    assert.is_not_nil(find(timeline.rows(ctx), "Open a file to see its history"))
  end)

  it("follows the renamed file to its first commit, matching git log --follow", function()
    vim.cmd.edit(vim.fn.fnameescape(fix.root .. "/docs/guide.md"))
    local rows = timeline.rows(ctx)
    assert.equals("timeline_pin", rows[1].action)
    assert.is_not_nil(text(rows[1]):find("docs/guide.md", 1, true))
    assert.is_not_nil(find(rows, "Loading history"))

    refresh_status()
    rows = settle()
    local expected = vim.split(
      vim.trim(fix:git({ "log", "--follow", "--format=%H", "--", "docs/guide.md" })),
      "\n"
    )
    local revs = revisions(rows)
    local shas = {}
    for i, row in ipairs(revs) do
      shas[i] = row.arg
      assert.equals("timeline_open", row.action)
      assert.equals("docs/guide.md", row.data.path)
    end
    assert.same(expected, shas)
    assert.is_not_nil(text(revs[1]):find("rename: docs/guide.md <- GUIDE.md", 1, true))
    assert.is_not_nil(text(revs[1]):find("gitvim test", 1, true))
    assert.is_true(vim.startswith(text(revs[1]), "  ● "))
    assert.is_true(vim.startswith(text(revs[2]), "  ● "))

    local rename = find(rows, "renamed from GUIDE.md")
    assert.is_not_nil(rename)
    assert.equals(expected[1], rename.arg)
    assert.equals("GitVimRenamed", rename[#rename].hl)
  end)

  it("stops at the rename when follow_renames is off", function()
    setup({ timeline = { follow_renames = false } })
    timeline.pin(store, "docs/guide.md")
    refresh_status()
    assert.equals(1, #revisions(settle()))
  end)

  it("reviews a revision against its parent, across the rename", function()
    timeline.pin(store, "docs/guide.md")
    refresh_status()
    local rows = revisions(settle())

    local calls = reviews(function()
      timeline.actions.timeline_open(ctx, rows[1].arg, rows[1])
      timeline.actions.timeline_open(ctx, rows[2].arg, rows[2])
    end)
    assert.same({
      {
        repo.root,
        "docs/guide.md",
        { left_rev = fix:sha("HEAD~3"), right_rev = fix:sha("HEAD~2"), left_path = "GUIDE.md" },
      },
      {
        repo.root,
        "GUIDE.md",
        {
          left_rev = require("gitvim.git.log").EMPTY_TREE,
          right_rev = fix:sha("HEAD~3"),
          left_path = "GUIDE.md",
        },
      },
    }, calls)
  end)

  it("reviews a revision against the working tree", function()
    timeline.pin(store, "docs/guide.md")
    refresh_status()
    local rows = revisions(settle())

    local calls = reviews(function()
      timeline.actions.timeline_worktree(ctx, rows[2].arg, rows[2])
    end)
    assert.same({
      { repo.root, "docs/guide.md", { left_rev = fix:sha("HEAD~3"), left_path = "GUIDE.md" } },
    }, calls)
  end)

  it("follows the buffer until pinned", function()
    vim.cmd.edit(vim.fn.fnameescape(fix.root .. "/docs/guide.md"))
    refresh_status()
    settle()
    timeline.actions.timeline_pin(ctx)
    assert.is_not_nil(text(timeline.rows(ctx)[1]):find("(pinned)", 1, true))

    vim.cmd.edit(vim.fn.fnameescape(fix.root .. "/README.md"))
    assert.is_not_nil(text(timeline.rows(ctx)[1]):find("docs/guide.md", 1, true))

    timeline.actions.timeline_pin(ctx)
    local rows = settle()
    assert.is_not_nil(text(rows[1]):find("README.md", 1, true))
    assert.is_nil(text(rows[1]):find("(pinned)", 1, true))
    assert.equals(2, #revisions(rows))
  end)

  it("keeps the last file while a scratch buffer is shown", function()
    vim.cmd.edit(vim.fn.fnameescape(fix.root .. "/docs/guide.md"))
    refresh_status()
    settle()
    vim.cmd.enew()
    vim.bo.buftype = "nofile"
    assert.is_not_nil(text(timeline.rows(ctx)[1]):find("docs/guide.md", 1, true))
  end)

  it("pins the first file seen when follow_buffer is off", function()
    setup({ timeline = { follow_buffer = false } })
    vim.cmd.edit(vim.fn.fnameescape(fix.root .. "/docs/guide.md"))
    refresh_status()
    settle()
    vim.cmd.edit(vim.fn.fnameescape(fix.root .. "/README.md"))
    local rows = timeline.rows(ctx)
    assert.is_not_nil(text(rows[1]):find("docs/guide.md", 1, true))
    assert.is_not_nil(text(rows[1]):find("(pinned)", 1, true))
  end)

  describe("empty states", function()
    it("says an untracked file has no history, without asking git", function()
      timeline.pin(store, "spaced ünicode.txt")
      refresh_status()
      assert.is_not_nil(find(timeline.rows(ctx), "Untracked: no history yet."))
      assert.is_nil(store.timeline.history)
    end)

    it("says a staged, never-committed file is not committed yet", function()
      timeline.pin(store, "staged.lua")
      refresh_status()
      assert.is_not_nil(find(settle(), "Not committed yet."))
    end)

    it("says a missing file has no history", function()
      timeline.pin(store, "nowhere.lua")
      refresh_status()
      assert.is_not_nil(find(settle(), "No history."))
    end)
  end)

  describe("paging", function()
    before_each(function()
      setup({ timeline = { page_size = 1 } })
      timeline.pin(store, "docs/guide.md")
    end)

    it("offers the next page as a reach row, and runs the lane on across it", function()
      refresh_status()
      local rows = settle()
      assert.equals(1, #revisions(rows))
      local tail = rows[#rows]
      assert.equals("timeline_more", tail.reach)
      assert.equals("timeline_more", tail.action)
      assert.is_not_nil(text(find(rows, "renamed from") --[[@as table]]):find("^  │ "))

      timeline.actions.timeline_more(ctx)
      assert.is_not_nil(find(timeline.rows(ctx), "Loading more"))
      rows = settle()
      assert.equals(2, #revisions(rows))
      -- That was the last page, so there is nothing more to offer.
      assert.equals("timeline_revision", rows[#rows].data.type)
    end)

    it("reloads as deep as it was scrolled", function()
      refresh_status()
      settle()
      timeline.actions.timeline_more(ctx)
      settle()
      store:mark_dirty("timeline")
      timeline.rows(ctx)
      assert.is_true(store.timeline.history.loading)
      assert.equals(2, #revisions(settle()))
    end)
  end)

  describe("staleness", function()
    it("reloads when HEAD moves", function()
      timeline.pin(store, "docs/guide.md")
      refresh_status()
      settle()
      fix:write("docs/guide.md", "rewritten\n")
      fix:git({ "commit", "-am", "docs: rewrite" })
      refresh_status()
      local rows = revisions(settle())
      assert.equals(3, #rows)
      assert.equals(fix:sha("HEAD"), rows[1].arg)
    end)

    it("does not reload while nothing changed", function()
      timeline.pin(store, "docs/guide.md")
      refresh_status()
      settle()
      local generation = store.timeline.history.generation
      timeline.rows(ctx)
      assert.equals(generation, store.timeline.history.generation)
      assert.is_false(store.timeline.history.loading)
    end)

    it("announces each arrival on the timeline event", function()
      local seen = 0
      state.subscribe("timeline", function(payload)
        assert.equals(repo.root, payload.root)
        seen = seen + 1
      end)
      timeline.pin(store, "docs/guide.md")
      refresh_status()
      settle()
      assert.equals(1, seen)
    end)
  end)
end)
