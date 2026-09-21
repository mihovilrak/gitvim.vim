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
  ---@param row gitvim.render.Row
  ---@return string[]
  local function row_buttons(row)
    local out = {}
    for _, chunk in ipairs(row) do
      if chunk.hl == "GitVimButton" or chunk.hl == "GitVimButtonActive" then
        out[#out + 1] = chunk.action
      end
    end
    return out
  end

  it("puts the commit line first, showing the draft's subject", function()
    local row = scm.rows(ctx)[1]
    assert.equals("scm_commit", row.data.type)
    assert.equals("commit", row.action)
    assert.is_truthy(text(row):match("Message"))
    assert.equals("Commit", vim.trim(row[#row].text))
    assert.equals("GitVimButtonActive", row[#row].hl)

    store.draft = "feat: a subject\n\nand a body"
    row = scm.rows(ctx)[1]
    assert.equals("feat: a subject", row[2].text)
    assert.is_nil(text(row):match("body"))

    store.draft = ("x"):rep(200)
    assert.equals(ctx.width - 1, vim.api.nvim_strwidth(text(scm.rows(ctx)[1])))
  end)

  it("says when there is nothing staged to commit", function()
    fix:git({ "reset", "-q" })
    local _, result = await(function(done)
      require("gitvim.git.status").get(repo.root, nil, done)
    end)
    store:set_status(result)
    local row = scm.rows(ctx)[1]
    assert.equals("Commit (nothing staged)", vim.trim(row[#row].text))
    assert.equals("GitVimButton", row[#row].hl)
  end)

  it("offers each group's buttons on its file rows, right-aligned", function()
    local rows = scm.rows(ctx)
    local cases = {
      { "staged.lua", "staged", { "unstage" }, "[-]" },
      { "modified.lua", "changes", { "discard", "stage" }, "[<] [+]" },
      { "spaced ünicode.txt", "untracked", { "discard", "stage" }, "[<] [+]" },
    }
    for _, case in ipairs(cases) do
      local row = entry_row(rows, case[1], case[2])
      assert.same(case[3], row_buttons(row))
      assert.is_truthy(vim.endswith(text(row), case[4]), case[1])
      assert.equals(ctx.width - 1, vim.api.nvim_strwidth(text(row)), case[1])
    end
  end)

  it("offers the group's buttons on its header, keeping the count last", function()
    local header = group_header(scm.rows(ctx), "changes")
    assert.same({ "discard", "stage" }, row_buttons(header))
    assert.is_truthy(text(header):match("%[<%] %[%+%] %d+$"))
    assert.equals("GitVimCount", header[#header].hl)
  end)

  it("hides the buttons when row_actions is off", function()
    config.setup({ icons = { style = "ascii" }, scm = { row_actions = false } })
    local rows = scm.rows(ctx)
    assert.same({}, row_buttons(entry_row(rows, "modified.lua", "changes")))
    local header = group_header(rows, "changes")
    assert.equals(tostring(#store:groups().changes), header[#header].text)
  end)

  describe("actions", function()
    local select

    before_each(function()
      repo_mod.set_active(repo.root)
      select = vim.ui.select
    end)

    after_each(function()
      vim.ui.select = select
    end)

    --- `git status` for one path, straight from git.
    ---@param path string
    ---@return string
    local function xy(path)
      return fix:git({ "status", "--porcelain", "--", path }):sub(1, 2)
    end

    ---@param pred fun(): boolean
    local function eventually(pred)
      assert.is_true(vim.wait(2000, pred, 10))
    end

    it("stages and unstages a file row, and the store follows", function()
      scm.actions.stage(ctx, nil, entry_row(scm.rows(ctx), "modified.lua", "changes"))
      eventually(function()
        return helpers.entry(store.status, "modified.lua", "staged") ~= nil
      end)
      assert.equals("M ", xy("modified.lua"))

      scm.actions.toggle_stage(ctx, nil, entry_row(scm.rows(ctx), "modified.lua", "staged"))
      eventually(function()
        return helpers.entry(store.status, "modified.lua", "changes") ~= nil
      end)
      assert.equals(" M", xy("modified.lua"))
    end)

    it("stages a whole group from its header", function()
      scm.actions.stage(ctx, nil, group_header(scm.rows(ctx), "untracked"))
      eventually(function()
        return #store:groups().untracked == 0
      end)
      assert.equals("A ", xy("spaced ünicode.txt"))
      assert.equals(" M", xy("modified.lua"), "other groups are left alone")
    end)

    it("ignores a button the row does not offer", function()
      scm.actions.unstage(ctx, nil, entry_row(scm.rows(ctx), "modified.lua", "changes"))
      scm.actions.discard(ctx, nil, entry_row(scm.rows(ctx), "staged.lua", "staged"))
      scm.actions.stage(ctx, nil, scm.rows(ctx)[1])
      vim.wait(200)
      assert.equals(" M", xy("modified.lua"))
      assert.equals("AM", xy("staged.lua"))
    end)

    it("asks before discarding and does nothing when cancelled", function()
      local prompts = {}
      vim.ui.select = function(items, opts, cb) ---@diagnostic disable-line: duplicate-set-field
        prompts[#prompts + 1] = opts.prompt
        cb(nil)
      end
      scm.actions.discard(ctx, nil, entry_row(scm.rows(ctx), "modified.lua", "changes"))
      vim.wait(200)
      assert.same({ "Discard changes to 'modified.lua'?" }, prompts)
      assert.equals(" M", xy("modified.lua"))
    end)

    it("discards once confirmed", function()
      vim.ui.select = function(items, _, cb) ---@diagnostic disable-line: duplicate-set-field
        cb(items[1])
      end
      scm.actions.discard(ctx, nil, entry_row(scm.rows(ctx), "spaced ünicode.txt", "untracked"))
      eventually(function()
        return #store:groups().untracked == 0
      end)
      assert.equals(0, vim.fn.filereadable(fix.root .. "/spaced ünicode.txt"))
    end)

    it("skips the prompt when confirm_discard is off", function()
      config.setup({ icons = { style = "ascii" }, scm = { confirm_discard = false } })
      vim.ui.select = function() ---@diagnostic disable-line: duplicate-set-field
        error("should not prompt")
      end
      scm.actions.discard(ctx, nil, entry_row(scm.rows(ctx), "modified.lua", "changes"))
      eventually(function()
        return helpers.entry(store.status, "modified.lua", "changes") == nil
      end)
      assert.equals("", xy("modified.lua"))
    end)
  end)
end)
