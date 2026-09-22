--- The Search tab's results and replace, against the fixture.

local config = require("gitvim.config")
local fixture = require("fixture")
local helpers = require("helpers")
local repo_mod = require("gitvim.git.repo")
local sidebar = require("gitvim.ui.sidebar")
local state = require("gitvim.state")
local tabs = require("gitvim.ui.tabs")

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
---@param kind string
---@return gitvim.render.Row[]
local function of_type(rows, kind)
  return vim.tbl_filter(function(row)
    return row.data and row.data.type == kind
  end, rows)
end

---@param row gitvim.render.Row
---@param hl string
---@return string[]
local function chunks_with(row, hl)
  local out = {}
  for _, chunk in ipairs(row) do
    if chunk.hl == hl then
      out[#out + 1] = chunk.text
    end
  end
  return out
end

--- Stub `vim.ui.select` for the duration of `fn`, answering `choice`.
---@return string? prompt  what was asked, nil if nothing was
local function answering(choice, fn)
  local select, prompt = vim.ui.select, nil
  vim.ui.select = function(_, opts, cb)
    prompt = opts.prompt
    cb(choice)
  end
  local ok, err = pcall(fn)
  vim.ui.select = select
  assert(ok, err)
  return prompt
end

---@param path string
---@return string
local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

describe("search tab", function()
  local fix, search, ctx

  --- Run the form's search and wait for the results.
  local function run()
    await(function(done)
      search.run(ctx.store, done)
    end)
  end

  --- Wait for the re-run a replace kicks off.
  local function settle()
    vim.wait(2000, function()
      return ctx.store.results == nil or not ctx.store.results.running
    end, 10)
  end

  before_each(function()
    config.setup({})
    state.reset()
    repo_mod.reset()
    vim.cmd("silent! only")
    fix = fixture.build()
    fix:write("a.txt", "foo one\n  bar foo foo\nnothing\n")
    fix:write("b.txt", "foo\n")
    local _, repo = await(function(done)
      repo_mod.detect(fix.root, done)
    end)
    repo_mod.set_active(repo.root)
    search = tabs.get("search")
    ctx = { repo = repo, store = state.get(repo.root), width = 40, focused = true }
    ctx.store.search.pattern = "foo"
    ctx.store.search.case = true
  end)

  after_each(function()
    sidebar.reset()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):find(fix.root, 1, true) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    fix:destroy()
    state.reset()
    repo_mod.reset()
    config.setup({})
  end)

  it("lists matches grouped by file", function()
    run()
    local rows = search.rows(ctx)
    local files = of_type(rows, "search_file")
    assert.same({ "a.txt", "b.txt" }, {
      files[1].data.path,
      files[2].data.path,
    })
    assert.truthy(text(files[1]):find("a.txt 3", 1, true))

    local matches = of_type(rows, "search_match")
    assert.equal(3, #matches)
    -- Indentation dropped, every match highlighted.
    assert.equal("    bar foo foo", text(matches[2]))
    assert.same({ "foo", "foo" }, chunks_with(matches[2], "GitVimMatch"))

    local summary = vim.iter(rows):find(function(row)
      return text(row):find("results in", 1, true)
    end)
    assert.equal(" 4 results in 2 files", text(summary))
  end)

  it("collapses a file", function()
    run()
    search.actions.toggle_file(ctx, "a.txt")
    local matches = of_type(search.rows(ctx), "search_match")
    assert.equal(1, #matches)
    assert.equal("b.txt", matches[1].data.path)
    search.actions.toggle_file(ctx, "a.txt")
    assert.equal(3, #of_type(search.rows(ctx), "search_match"))
  end)

  it("previews the replacement on every match", function()
    ctx.store.search.replace = "baz"
    run()
    local rows = search.rows(ctx)
    local row = of_type(rows, "search_match")[2]
    assert.same({ "foo", "foo" }, chunks_with(row, "GitVimMatchRemoved"))
    assert.same({ "baz", "baz" }, chunks_with(row, "GitVimReplace"))
    local all = vim.iter(rows):find(function(r)
      return text(r):find("[replace all]", 1, true)
    end)
    assert.truthy(all)
  end)

  it("says when nothing matched", function()
    ctx.store.search.pattern = "no such text"
    run()
    assert.truthy(vim.iter(search.rows(ctx)):find(function(row)
      return text(row):find("No results.", 1, true)
    end))
  end)

  it("clears the results with the pattern", function()
    run()
    search.actions.clear(ctx)
    vim.wait(100)
    assert.is_nil(ctx.store.results)
    assert.equal(0, #of_type(search.rows(ctx), "search_file"))
  end)

  it("opens a match in the editor window at its line and column", function()
    run()
    sidebar.open("search")
    local dock = vim.api.nvim_get_current_win()
    local row = of_type(search.rows(ctx), "search_match")[2]
    search.actions.open_match(ctx, row.arg)

    local win = vim.api.nvim_get_current_win()
    assert.are_not.equal(dock, win)
    assert.equal(
      vim.fs.normalize(fix.root .. "/a.txt"),
      vim.fs.normalize(vim.api.nvim_buf_get_name(0))
    )
    assert.same({ 2, 6 }, vim.api.nvim_win_get_cursor(win))
  end)

  it("replaces a file in one undo step, and writes it", function()
    ctx.store.search.replace = "X"
    run()
    local file = ctx.store.results.result.files[1]
    assert.equal(3, search.apply_file(fix.root, file, "X"))
    assert.equal("X one\n  bar X X\nnothing", read(fix.root .. "/a.txt"))

    local buf = vim.fn.bufnr(fix.root .. "/a.txt")
    assert.is_false(vim.bo[buf].modified)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent undo")
    end)
    assert.same(
      { "foo one", "  bar foo foo", "nothing" },
      vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    )
  end)

  it("leaves a buffer with unsaved edits unsaved", function()
    run()
    local buf = vim.fn.bufadd(fix.root .. "/a.txt")
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "edited" })

    search.apply_file(fix.root, ctx.store.results.result.files[1], "X")
    assert.is_true(vim.bo[buf].modified)
    assert.equal("foo one\n  bar foo foo\nnothing", read(fix.root .. "/a.txt"))
    assert.same({ "X one", "  bar X X", "edited" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("skips a line that changed since the search", function()
    run()
    fix:write("a.txt", "foo one\nchanged foo\nnothing\n")
    assert.equal(1, search.apply_file(fix.root, ctx.store.results.result.files[1], "X"))
    assert.equal("X one\nchanged foo\nnothing", read(fix.root .. "/a.txt"))
  end)

  it("asks before replacing all, and does nothing on cancel", function()
    ctx.store.search.replace = "X"
    run()
    local prompt = answering("Cancel", function()
      search.actions.replace_all(ctx)
    end)
    assert.equal("Replace 4 matches in 2 files with 'X'?", prompt)
    assert.equal("foo", read(fix.root .. "/b.txt"))

    answering("Replace", function()
      search.actions.replace_all(ctx)
    end)
    settle()
    assert.equal("X one\n  bar X X\nnothing", read(fix.root .. "/a.txt"))
    assert.equal("X", read(fix.root .. "/b.txt"))
  end)

  it("replaces without asking when confirm_replace is off", function()
    config.setup({ search = { confirm_replace = false } })
    ctx.store.search.replace = "X"
    run()
    local prompt = answering("Cancel", function()
      search.actions.replace_all(ctx)
    end)
    settle()
    assert.is_nil(prompt)
    assert.equal("X", read(fix.root .. "/b.txt"))
  end)

  it("replaces one line with r on a match row", function()
    ctx.store.search.replace = "X"
    run()
    local row = of_type(search.rows(ctx), "search_match")[2]
    search.actions.replace(ctx, row.arg, row)
    settle()
    assert.equal("foo one\n  bar X X\nnothing", read(fix.root .. "/a.txt"))
    assert.equal("foo", read(fix.root .. "/b.txt"))
  end)
end)
