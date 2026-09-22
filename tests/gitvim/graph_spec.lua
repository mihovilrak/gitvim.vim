--- The GRAPH section, asserted as render rows against the fixture.

local config = require("gitvim.config")
local fixture = require("fixture")
local graph = require("gitvim.ui.sections.graph")
local helpers = require("helpers")
local repo_mod = require("gitvim.git.repo")
local state = require("gitvim.state")

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

--- A file row of an expanded commit; commit subjects mention paths too.
---@param rows gitvim.render.Row[]
---@param needle string  plain text
---@return gitvim.render.Row?
local function file(rows, needle)
  for _, row in ipairs(rows) do
    if row.data and row.data.type == "graph_file" and text(row):find(needle, 1, true) then
      return row
    end
  end
end

---@param rows gitvim.render.Row[]
---@return gitvim.render.Row[]
local function commits(rows)
  return vim.tbl_filter(function(row)
    return row.data and row.data.type == "graph_commit"
  end, rows)
end

---@param row gitvim.render.Row
---@param needle string
---@return string?
local function hl_of(row, needle)
  for _, chunk in ipairs(row) do
    if chunk.text == needle then
      return chunk.hl
    end
  end
end

--- The highlight of a row's node glyph.
---@param row gitvim.render.Row
---@return string?
local function node_hl(row)
  for _, chunk in ipairs(row) do
    if chunk.text:find("●", 1, true) then
      return chunk.hl
    end
  end
end

describe("GRAPH section", function()
  local fix, repo, store, ctx

  --- Read status into the store, as the refresh loop would.
  local function refresh_status()
    local err, result = await(function(done)
      require("gitvim.git.status").get(repo.root, nil, done)
    end)
    assert.is_nil(err)
    store:set_status(result)
  end

  --- Render until every load in flight has landed, then render once more.
  ---@return gitvim.render.Row[]
  local function settle()
    local ok = vim.wait(5000, function()
      graph.rows(ctx)
      local g = store.graph
      if not (g and g.loaded and not g.loading) then
        return false
      end
      for _, files in pairs(g.open) do
        if files == false then
          return false
        end
      end
      return true
    end, 10)
    assert.is_true(ok, "the history should have loaded")
    return graph.rows(ctx)
  end

  ---@param opts? table  extra config
  local function setup(opts)
    config.setup(vim.tbl_deep_extend("force", { icons = { style = "ascii" } }, opts or {}))
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
  end)

  after_each(function()
    fix:destroy()
    state.reset()
    repo_mod.reset()
    config.setup({})
  end)

  it("says so outside a repository", function()
    assert.is_not_nil(find(graph.rows({ width = 40 }), "Not a git repository"))
  end)

  it("waits for status before loading, then draws every commit", function()
    local rows = graph.rows(ctx)
    assert.is_not_nil(find(rows, "Loading history"))
    assert.is_false(store.graph.loading)

    refresh_status()
    rows = commits(settle())
    assert.equals(5, #rows)
    assert.is_not_nil(text(rows[1]):find("merge branch 'feature'", 1, true))
    assert.equals(fix:sha("HEAD"), rows[1].arg)
    assert.equals("graph_toggle", rows[1].action)
  end)

  it("draws the lanes of a branch and its merge", function()
    refresh_status()
    local rows = commits(settle())
    local pictures = { "●─╮", "● │", "│ ●", "●─╯", "●" }
    for i, picture in ipairs(pictures) do
      assert.is_true(
        vim.startswith(text(rows[i]), "  " .. picture .. " "),
        ("row %d should start with %q: %q"):format(i, picture, text(rows[i]))
      )
    end
  end)

  it("colors each branch's lane apart, and HEAD's node on its own", function()
    refresh_status()
    local rows = commits(settle())
    assert.equals("GitVimGraphNode", node_hl(rows[1]))

    local main = node_hl(rows[2])
    local feature = node_hl(rows[3])
    assert.matches("^GitVimGraphLane%d$", main)
    assert.matches("^GitVimGraphLane%d$", feature)
    assert.are_not.equal(main, feature)
  end)

  it("badges refs by kind, the current branch as HEAD", function()
    fix:git({ "tag", "v1", "HEAD~1" })
    refresh_status()
    local rows = settle()
    assert.equals("GitVimRefHead", hl_of(find(rows, "merge branch"), "main"))
    assert.equals("GitVimRefLocal", hl_of(find(rows, "feat: add widget"), "feature"))
    assert.equals("GitVimRefTag", hl_of(find(rows, "fix: tweak README"), "v1"))
  end)

  it("hides the badges when show_refs is off", function()
    setup({ graph = { show_refs = false } })
    refresh_status()
    assert.is_nil(hl_of(find(settle(), "merge branch"), "main"))
  end)

  it("right-aligns author and date, truncating the subject to fit", function()
    refresh_status()
    local row = find(settle(), "merge branch")
    assert.is_true(
      vim.endswith(text(row), "gitvim test " .. graph.format_date(row.data.commit.time))
    )
    assert.equals(ctx.width - 1, vim.api.nvim_strwidth(text(row)))

    ctx.width = 34
    row = commits(graph.rows(ctx))[1]
    assert.is_true(vim.api.nvim_strwidth(text(row)) <= ctx.width)
    assert.is_not_nil(text(row):find("…", 1, true))
  end)

  it("reuses commit rows across renders until the width changes", function()
    refresh_status()
    local first = commits(settle())[1]
    assert.equals(first, commits(graph.rows(ctx))[1])
    ctx.width = 50
    assert.are_not.equal(first, commits(graph.rows(ctx))[1])
  end)

  describe("format_date", function()
    local now = 1700000000

    it("reads relative ages", function()
      assert.equals("now", graph.format_date(now - 30, "relative", now))
      assert.equals("1 min ago", graph.format_date(now - 60, "relative", now))
      assert.equals("2 hours ago", graph.format_date(now - 7200, "relative", now))
      assert.equals("1 day ago", graph.format_date(now - 86400, "relative", now))
      assert.equals("3 weeks ago", graph.format_date(now - 21 * 86400, "relative", now))
      assert.equals("2 years ago", graph.format_date(now - 800 * 86400, "relative", now))
      assert.equals("now", graph.format_date(now + 100, "relative", now))
    end)

    it("prints absolute dates", function()
      assert.equals(os.date("%Y-%m-%d", now), graph.format_date(now, "short"))
      assert.equals(os.date("%Y-%m-%d %H:%M", now), graph.format_date(now, "iso"))
    end)
  end)

  describe("commit detail", function()
    it("expands a commit to its files, renames included, and collapses it", function()
      refresh_status()
      settle()
      local sha = fix:sha("HEAD~2")
      graph.actions.graph_toggle(ctx, sha)
      assert.is_not_nil(find(graph.rows(ctx), "Loading files"))

      local rows = settle()
      local row = file(rows, "GUIDE.md → docs/guide.md")
      assert.is_not_nil(row)
      assert.equals("graph_open", row.action)
      assert.equals("docs/guide.md", row.arg)
      assert.equals("docs/guide.md", row.data.path)

      graph.actions.graph_toggle(ctx, sha)
      assert.is_nil(file(graph.rows(ctx), "docs/guide.md"))
    end)

    it("opens the review on a file against the commit's first parent", function()
      refresh_status()
      settle()
      local sha = fix:sha("HEAD~2")
      graph.actions.graph_toggle(ctx, sha)
      local row = file(settle(), "docs/guide.md")

      local review = require("gitvim.ui.review")
      local original = review.open
      local calls = {}
      review.open = function(...)
        calls[#calls + 1] = { ... }
      end
      local ok, err = pcall(graph.actions.graph_open, ctx, row.arg, row)
      review.open = original
      assert.is_true(ok, err)

      assert.same({
        {
          repo.root,
          "docs/guide.md",
          { left_rev = fix:sha("HEAD~3"), right_rev = sha, left_path = "GUIDE.md" },
        },
      }, calls)
    end)

    it("diffs a root commit against the empty tree", function()
      refresh_status()
      settle()
      local root_sha = fix:sha("HEAD~3")
      graph.actions.graph_toggle(ctx, root_sha)
      local row = file(settle(), "GUIDE.md")
      assert.equals(
        require("gitvim.git.log").EMPTY_TREE,
        require("gitvim.git.log").base(row.data.commit)
      )
    end)
  end)

  describe("paging", function()
    before_each(function()
      setup({ graph = { page_size = 2 } })
    end)

    it("offers the next page as a reach row, and continues the lanes across it", function()
      refresh_status()
      local rows = settle()
      assert.equals(2, #commits(rows))
      local tail = rows[#rows]
      assert.equals("graph_more", tail.reach)
      assert.equals("graph_more", tail.action)

      graph.actions.graph_more(ctx)
      assert.is_not_nil(find(graph.rows(ctx), "Loading more"))
      rows = settle()
      assert.equals(4, #commits(rows))

      graph.actions.graph_more(ctx)
      rows = settle()
      local all = commits(rows)
      assert.equals(5, #all)
      assert.equals("graph_commit", rows[#rows].data.type, "no tail row at the end of history")

      local pictures = { "●─╮", "● │", "│ ●", "●─╯", "●" }
      for i, picture in ipairs(pictures) do
        assert.is_true(vim.startswith(text(all[i]), "  " .. picture .. " "))
      end
    end)

    it("reloads as deep as it was scrolled", function()
      refresh_status()
      settle()
      graph.actions.graph_more(ctx)
      settle()
      store:mark_dirty("graph")
      graph.rows(ctx)
      assert.is_true(store.graph.loading)
      assert.equals(4, #commits(settle()))
    end)

    it("pages until a cross-navigated commit turns up, then expands and reveals it", function()
      local sidebar = require("gitvim.ui.sidebar")
      local original = sidebar.reveal
      local revealed = {}
      sidebar.reveal = function(action, arg)
        revealed[#revealed + 1] = { action, arg }
      end

      refresh_status()
      local sha = fix:sha("HEAD~3")
      store.graph_commit = sha:sub(1, 7)
      local ok = vim.wait(5000, function()
        graph.rows(ctx)
        return #revealed > 0
      end, 10)
      sidebar.reveal = original

      assert.is_true(ok, "the commit should have been revealed")
      assert.is_nil(store.graph_commit)
      assert.same({ { "graph_toggle", sha } }, revealed)
      assert.is_not_nil(store.graph.open[sha])
      assert.is_not_nil(file(settle(), "GUIDE.md"))
    end)

    it("warns about a commit that is not in the history", function()
      local notify = vim.notify
      local messages = {}
      vim.notify = function(msg)
        messages[#messages + 1] = msg
      end

      refresh_status()
      store.graph_commit = "deadbeef"
      vim.wait(5000, function()
        graph.rows(ctx)
        return store.graph_commit == nil
      end, 10)
      vim.notify = notify

      assert.is_nil(store.graph_commit)
      assert.is_not_nil(messages[1] and messages[1]:find("deadbeef", 1, true))
    end)
  end)

  describe("staleness", function()
    it("reloads when HEAD moves", function()
      refresh_status()
      settle()
      fix:git({ "commit", "--allow-empty", "-m", "chore: later" })
      refresh_status()
      local rows = commits(settle())
      assert.equals(6, #rows)
      assert.is_not_nil(text(rows[1]):find("chore: later", 1, true))
    end)

    it("does not reload while nothing changed", function()
      refresh_status()
      settle()
      local generation = store.graph.generation
      graph.rows(ctx)
      refresh_status()
      graph.rows(ctx)
      assert.equals(generation, store.graph.generation)
    end)

    it("reloads when the slot is marked dirty", function()
      refresh_status()
      settle()
      fix:git({ "branch", "side", "HEAD~1" })
      store:mark_dirty("graph")
      local rows = settle()
      assert.equals("GitVimRefLocal", hl_of(find(rows, "fix: tweak README"), "side"))
    end)

    it("announces each arrival on the graph event", function()
      local seen = 0
      state.subscribe("graph", function(payload)
        assert.equals(store.root, payload.root)
        seen = seen + 1
      end)
      refresh_status()
      settle()
      assert.is_true(seen >= 1)
    end)
  end)
end)
