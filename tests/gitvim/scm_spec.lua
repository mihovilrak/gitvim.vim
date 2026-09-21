--- The read-only SOURCE CONTROL section, asserted as render rows.

local config = require("gitvim.config")
local fixture = require("fixture")
local helpers = require("helpers")
local icons = require("gitvim.ui.icons")
local repo_mod = require("gitvim.git.repo")
local scm = require("gitvim.ui.sections.scm")
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
---@param pattern string
---@return gitvim.render.Row?
local function find(rows, pattern)
  for _, row in ipairs(rows) do
    if text(row):match(pattern) then
      return row
    end
  end
end

---@param rows gitvim.render.Row[]
---@param group string
---@return gitvim.render.Row?
local function group_header(rows, group)
  for _, row in ipairs(rows) do
    if row.data and row.data.type == "scm_group" and row.data.group == group then
      return row
    end
  end
end

---@param rows gitvim.render.Row[]
---@param path string
---@param group? string
---@return gitvim.render.Row?
local function entry_row(rows, path, group)
  for _, row in ipairs(rows) do
    local entry = row.data
    if entry and entry.path == path and (not group or entry.group == group) then
      return row
    end
  end
end

describe("SOURCE CONTROL section", function()
  local fix, repo, store, ctx

  before_each(function()
    config.setup({ icons = { style = "ascii" } })
    state.reset()
    repo_mod.reset()
    fix = fixture.build()
    local _, found = await(function(done)
      repo_mod.detect(fix.root, done)
    end)
    repo = found
    store = state.get(repo.root)
    local err, result = await(function(done)
      require("gitvim.git.status").get(repo.root, nil, done)
    end)
    assert.is_nil(err)
    store:set_status(result)
    ctx = { repo = repo, store = store, width = 40, focused = true }
  end)

  after_each(function()
    fix:destroy()
    icons.reset()
    state.reset()
    repo_mod.reset()
    config.setup({})
  end)

  it("matches every fixture entry to its porcelain group", function()
    local rows = scm.rows(ctx)
    local expected = store:groups()
    for _, group in ipairs({ "merge", "staged", "changes", "untracked" }) do
      if #expected[group] == 0 then
        assert.is_nil(group_header(rows, group))
      else
        local header = group_header(rows, group)
        assert.is_table(header)
        assert.equals(tostring(#expected[group]), header[#header].text)
        for _, entry in ipairs(expected[group]) do
          assert.is_table(entry_row(rows, entry.path, group), group .. ": " .. entry.path)
        end
      end
    end
  end)

  it("uses the configured group order and omits empty groups", function()
    config.setup({ scm = { groups = { "untracked", "merge", "changes", "staged" } } })
    local rows = scm.rows(ctx)
    local untracked, changes, staged
    for i, row in ipairs(rows) do
      if row.data and row.data.type == "scm_group" then
        if row.data.group == "untracked" then
          untracked = i
        elseif row.data.group == "changes" then
          changes = i
        elseif row.data.group == "staged" then
          staged = i
        end
      end
    end
    assert.is_true(untracked < changes and changes < staged)
    assert.is_nil(group_header(rows, "merge"))
  end)

  it("renders the status letter with the status color", function()
    local cases = {
      { "staged.lua", "staged", "A", "GitVimAdded" },
      { "modified.lua", "changes", "M", "GitVimModified" },
      { "deleted.lua", "changes", "D", "GitVimDeleted" },
      { "spaced ünicode.txt", "untracked", "U", "GitVimUntracked" },
    }
    local rows = scm.rows(ctx)
    for _, case in ipairs(cases) do
      local row = entry_row(rows, case[1], case[2])
      assert.equals(case[3], row[2].text)
      assert.equals(case[4], row[2].hl)
    end
  end)

  it("dims directories and colors the basename", function()
    store:set_status({
      branch = store.status.branch,
      entries = {
        { path = "deep/path/file.lua", x = ".", y = "M", group = "changes", kind = "modified" },
      },
    })
    local row = entry_row(scm.rows(ctx), "deep/path/file.lua")
    assert.equals("deep/path/", row[4].text)
    assert.equals("GitVimDir", row[4].hl)
    assert.equals("file.lua", row[5].text)
    assert.equals("GitVimModified", row[5].hl)
  end)

  it("includes the filetype icon when nerd icons are enabled", function()
    config.setup({ icons = { style = "nerd" } })
    icons.reset()
    local want = icons.file("modified.lua", false)
    local row = entry_row(scm.rows(ctx), "modified.lua", "changes")
    local found = false
    for _, chunk in ipairs(row) do
      found = found or chunk.text == want
    end
    assert.is_true(found, "the filetype icon should be a chunk in the file row")
  end)

  it("renders a rename from its old path to its new path", function()
    store:set_status({
      branch = store.status.branch,
      entries = {
        {
          path = "docs/manual.md",
          orig_path = "docs/guide.md",
          x = "R",
          y = ".",
          group = "staged",
          kind = "renamed",
          score = 100,
        },
      },
    })
    local row = entry_row(scm.rows(ctx), "docs/manual.md")
    assert.equals("R", row[2].text)
    assert.is_truthy(text(row):match("docs/guide%.md → docs/manual%.md"))
    assert.equals("GitVimRenamed", row[2].hl)
  end)

  it("renders merge conflicts in their own orange group", function()
    store:set_status({
      branch = store.status.branch,
      entries = {
        {
          path = "conflicted.lua",
          x = "U",
          y = "U",
          group = "merge",
          kind = "conflict",
          conflict = "UU",
        },
      },
    })
    local rows = scm.rows(ctx)
    assert.is_table(group_header(rows, "merge"))
    local row = entry_row(rows, "conflicted.lua")
    assert.equals("!", row[2].text)
    assert.equals("GitVimConflict", row[2].hl)
  end)

  it("persists group collapse in the repository store", function()
    scm.actions.toggle_group(ctx, "changes")
    assert.is_true(store.collapsed.changes)
    assert.is_nil(entry_row(scm.rows(ctx), "modified.lua", "changes"))

    scm.actions.toggle_group(ctx, "changes")
    assert.is_false(store.collapsed.changes)
    assert.is_table(entry_row(scm.rows(ctx), "modified.lua", "changes"))
  end)

  it("honours the configured initial collapse state", function()
    config.setup({ scm = { collapsed = { "changes" } } })
    store.collapsed.changes = nil
    assert.is_table(group_header(scm.rows(ctx), "changes"))
    assert.is_nil(entry_row(scm.rows(ctx), "modified.lua", "changes"))
  end)

  it("distinguishes loading, clean, and non-repository states", function()
    local fresh = state.get("/tmp/gitvim-scm-loading")
    assert.is_table(
      find(scm.rows({ store = fresh, width = 40, focused = false }), "Loading status")
    )

    store:set_status({ branch = store.status.branch, entries = {} })
    assert.is_table(find(scm.rows(ctx), "No changes"))

    assert.is_table(find(scm.rows({ width = 40, focused = false }), "Not a git repository"))
  end)
end)
