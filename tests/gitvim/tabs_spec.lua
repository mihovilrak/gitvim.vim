--- The four activity tabs, asserted as data: `rows(ctx)` is pure, so none of
--- this needs a window.

local config = require("gitvim.config")
local fixture = require("fixture")
local helpers = require("helpers")
local repo_mod = require("gitvim.git.repo")
local state = require("gitvim.state")
local tabs = require("gitvim.ui.tabs")

local await = helpers.await

--- The rendered text of a row, chunks concatenated.
---@param row gitvim.render.Row
---@return string
local function text(row)
  local parts = {}
  for i, chunk in ipairs(row) do
    parts[i] = chunk.text or ""
  end
  return table.concat(parts)
end

--- The first row whose text matches `pattern`.
---@param rows gitvim.render.Row[]
---@param pattern string
---@return gitvim.render.Row?, integer?
local function find(rows, pattern)
  for i, row in ipairs(rows) do
    if text(row):match(pattern) then
      return row, i
    end
  end
  return nil, nil
end

---@param rows gitvim.render.Row[]
---@param pattern string
---@return boolean
local function has(rows, pattern)
  return find(rows, pattern) ~= nil
end

--- A context standing in for what the sidebar passes down.
---@return gitvim.ui.TabCtx
local function context(repo)
  return {
    repo = repo,
    store = repo and state.get(repo.root) or nil,
    width = 40,
    focused = true,
  }
end

describe("tabs.get", function()
  before_each(function()
    tabs.reset()
  end)

  it("loads all four activity tabs", function()
    for _, name in ipairs({ "files", "search", "git", "buffers" }) do
      local tab = tabs.get(name)
      assert.is_table(tab, name .. " did not load")
      assert.equals(name, tab.name)
      assert.is_function(tab.rows)
    end
  end)

  it("loads a tab once and hands back the same table after", function()
    assert.is_true(rawequal(tabs.get("git"), tabs.get("git")))
  end)

  it("labels the Search tab icon-only, and the rest with text", function()
    assert.equals("", tabs.get("search").title)
    assert.equals("Files", tabs.get("files").title)
    assert.equals("Git", tabs.get("git").title)
    assert.equals("Buffers", tabs.get("buffers").title)
  end)

  it("reports an unknown tab once, rather than on every redraw", function()
    local notify, messages = vim.notify, {}
    vim.notify = function(msg, level)
      messages[#messages + 1] = { msg = msg, level = level }
    end
    assert.is_nil(tabs.get("nonesuch"))
    assert.is_nil(tabs.get("nonesuch"))
    vim.notify = notify

    assert.equals(1, #messages)
    assert.equals(vim.log.levels.ERROR, messages[1].level)
    assert.is_truthy(messages[1].msg:match("nonesuch"))
  end)
end)

describe("tabs chrome", function()
  it("right-aligns a title's count as virtual text, never a new line", function()
    local row = tabs.title("OPEN EDITORS", "3")
    assert.equals("OPEN EDITORS", text(row))
    assert.equals("3 ", row.virt[1].text)
  end)

  it("gives a header a chevron that follows its open state", function()
    local icons = require("gitvim.ui.icons")
    local open = tabs.header({ text = "GRAPH", open = true, action = "toggle_section" })
    local shut = tabs.header({ text = "GRAPH", open = false, action = "toggle_section" })

    assert.equals(icons.chevron(true), open[1].text)
    assert.equals(icons.chevron(false), shut[1].text)
    assert.equals("toggle_section", open.action)
  end)

  it("shows a header count only when there is something to count", function()
    local none = text(tabs.header({ text = "S", open = true, action = "a", count = 0 }))
    local some = text(tabs.header({ text = "S", open = true, action = "a", count = 4 }))
    assert.is_falsy(none:match("0"))
    assert.is_truthy(some:match("4"))
  end)

  it("says the same thing in every tab when there is no repository", function()
    assert.is_true(has(tabs.no_repo(), "Not inside a git repository"))
  end)
end)

describe("Files tab", function()
  local files, fix, repo, ctx

  before_each(function()
    config.setup({})
    state.reset()
    repo_mod.reset()
    tabs.reset()
    files = tabs.get("files")
    fix = fixture.build()
    local _, found = await(function(done)
      repo_mod.detect(fix.root, done)
    end)
    repo = found
    ctx = context(repo)
  end)

  after_each(function()
    fix:destroy()
    state.reset()
    repo_mod.reset()
    config.setup({})
  end)

  it("titles the tree with the repository name", function()
    assert.equals(vim.fs.basename(fix.root):upper(), text(files.rows(ctx)[1]))
  end)

  it("lists the top level, directories before files", function()
    local rows = files.rows(ctx)
    local _, docs = find(rows, "docs")
    local _, readme = find(rows, "README")
    assert.is_number(docs)
    assert.is_number(readme)
    assert.is_true(docs < readme, "directories should sort above files")
  end)

  it("never shows .git, whatever show_hidden says", function()
    config.setup({ files = { show_hidden = true } })
    assert.is_false(has(files.rows(ctx), "%.git%f[%W]"))
  end)

  it("honours files.show_hidden for everything else", function()
    fix:write(".hidden", "x\n")
    config.setup({ files = { show_hidden = false } })
    assert.is_false(has(files.rows(ctx), "%.hidden"))
    config.setup({ files = { show_hidden = true } })
    assert.is_true(has(files.rows(ctx), "%.hidden"))
  end)

  it("keeps a directory's children hidden until it is expanded", function()
    assert.is_false(has(files.rows(ctx), "guide%.md"))

    files.actions.toggle_dir(ctx, fix.root .. "/docs")
    local rows = files.rows(ctx)
    local guide = find(rows, "guide%.md")
    assert.is_table(guide, "expanding docs/ should reveal guide.md")
    -- Indented one level deeper than its parent.
    assert.is_truthy(text(guide):match("^   "))
  end)

  it("remembers expansion per repository, in the store", function()
    files.actions.toggle_dir(ctx, fix.root .. "/docs")
    assert.is_true(ctx.store.expanded[fix.root .. "/docs"])
    files.actions.toggle_dir(ctx, fix.root .. "/docs")
    assert.is_falsy(ctx.store.expanded[fix.root .. "/docs"])
  end)

  it("folds everything back up with collapse_all", function()
    files.actions.toggle_dir(ctx, fix.root .. "/docs")
    files.actions.collapse_all(ctx)
    assert.same({}, ctx.store.expanded)
    assert.is_false(has(files.rows(ctx), "guide%.md"))
  end)

  it("carries the path as the row's action argument", function()
    local row = find(files.rows(ctx), "README")
    assert.equals("open", row.action)
    assert.equals(fix.root .. "/README.md", row.arg)

    local dir = find(files.rows(ctx), "docs")
    assert.equals("toggle_dir", dir.action)
  end)

  it("tints a file with its working-tree status", function()
    local hl = require("gitvim.ui.hl")
    local result = await(function(done)
      require("gitvim.git.status").get(fix.root, nil, function(_, res)
        done(res)
      end)
    end)
    ctx.store:set_status(result)

    local row = find(files.rows(ctx), "modified%.lua")
    assert.is_table(row)
    assert.equals(hl.kind.modified, row[#row].hl)
  end)

  it("says so, rather than drawing a tree, outside a repository", function()
    assert.is_true(has(files.rows({ width = 40, focused = false }), "Not inside a git repository"))
  end)
end)

describe("Search tab", function()
  local search, ctx

  before_each(function()
    config.setup({})
    state.reset()
    tabs.reset()
    search = tabs.get("search")
    ctx = { repo = nil, store = state.get("/tmp/gitvim-search-spec"), width = 40, focused = true }
  end)

  after_each(function()
    state.reset()
    config.setup({})
  end)

  it("draws the whole VS Code form: pattern, replace, include, exclude", function()
    local rows = search.rows(ctx)
    assert.is_true(has(rows, "SEARCH"))
    assert.is_true(has(rows, "Pattern"))
    assert.is_true(has(rows, "Replace"))
    assert.is_true(has(rows, "files to include"))
    assert.is_true(has(rows, "files to exclude"))
  end)

  it("puts the three toggles on the pattern label row, right-aligned", function()
    local row = find(search.rows(ctx), "Pattern")
    local line = text(row)
    assert.is_truthy(line:match("Aa"))
    assert.is_truthy(line:match("ab"))
    assert.is_truthy(line:match("%.%*"))
    -- Right-aligned means the buttons end at the window's edge.
    assert.equals(ctx.width, #line + 1)

    for _, chunk in ipairs(row) do
      if chunk.text == " Aa " then
        assert.equals("toggle_case", chunk.action)
      end
    end
  end)

  it("lights a toggle up when it is on", function()
    local function case_hl()
      for _, chunk in ipairs(find(search.rows(ctx), "Pattern")) do
        if chunk.text == " Aa " then
          return chunk.hl
        end
      end
    end

    assert.equals("GitVimToggleOff", case_hl())
    search.actions.toggle_case(ctx)
    assert.is_true(ctx.store.search.case)
    assert.equals("GitVimToggleOn", case_hl())
  end)

  it("shows a dimmed placeholder until a field has a value", function()
    local rows = search.rows(ctx)
    local _, label = find(rows, "Pattern")
    local value = rows[label + 1]
    assert.equals("GitVimFieldEmpty", value[2].hl)
    assert.equals("edit", value.action)
    assert.equals("pattern", value.arg)

    ctx.store.search.pattern = "needle"
    rows = search.rows(ctx)
    value = rows[select(2, find(rows, "Pattern")) + 1]
    assert.equals("  needle", text(value))
    assert.equals("GitVimField", value[2].hl)
  end)

  it("edits a field through vim.ui.input and redraws", function()
    local input = vim.ui.input
    vim.ui.input = function(opts, cb)
      assert.is_truthy(opts.prompt:match("Pattern"))
      cb("widget")
    end
    search.actions.edit(ctx, "pattern")
    vim.ui.input = input

    assert.equals("widget", ctx.store.search.pattern)
  end)

  it("leaves a field alone when the prompt is cancelled", function()
    ctx.store.search.pattern = "kept"
    local input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    search.actions.edit(ctx, "pattern")
    vim.ui.input = input

    assert.equals("kept", ctx.store.search.pattern)
  end)

  it("clears the pattern and replacement, but not the glob filters", function()
    ctx.store.search.pattern = "a"
    ctx.store.search.replace = "b"
    ctx.store.search.include = "*.lua"
    search.actions.clear(ctx)

    assert.equals("", ctx.store.search.pattern)
    assert.equals("", ctx.store.search.replace)
    assert.equals("*.lua", ctx.store.search.include)
  end)

  it("seeds the form from the config", function()
    config.setup({ search = { regex = true, include = "src/**" } })
    state.reset()
    local store = state.get("/tmp/gitvim-search-spec")
    assert.is_true(store.search.regex)
    assert.equals("src/**", store.search.include)
  end)
end)

describe("Git tab", function()
  local git, fix, repo, ctx

  before_each(function()
    config.setup({})
    state.reset()
    repo_mod.reset()
    tabs.reset()
    git = tabs.get("git")
    fix = fixture.build()
    local _, found = await(function(done)
      repo_mod.detect(fix.root, done)
    end)
    repo = found
    ctx = context(repo)
  end)

  after_each(function()
    fix:destroy()
    state.reset()
    repo_mod.reset()
    config.setup({})
  end)

  it("heads the panel with the repository and its branch", function()
    local row = git.rows(ctx)[1]
    assert.equals(repo.name, row[1].text)
    assert.equals(repo:head_label(), row[3].text)
    assert.equals("checkout", row[3].action)
  end)

  it("stacks SOURCE CONTROL, GRAPH and TIMELINE as sections of one panel", function()
    local rows = git.rows(ctx)
    assert.is_true(has(rows, "SOURCE CONTROL"))
    assert.is_true(has(rows, "GRAPH"))
    assert.is_true(has(rows, "TIMELINE"))

    local _, scm = find(rows, "SOURCE CONTROL")
    local _, graph = find(rows, "GRAPH")
    local _, timeline = find(rows, "TIMELINE")
    assert.is_true(scm < graph and graph < timeline, "sections should keep config order")
  end)

  it("starts with the configured sections folded", function()
    local rows = git.rows(ctx)
    -- scm is open by default, graph and timeline are not.
    assert.is_true(has(rows, "No working tree status yet"))
    assert.is_false(has(rows, "No commits loaded yet"))
  end)

  it("toggles a section, and remembers it in the store", function()
    git.actions.toggle_section(ctx, "graph")
    assert.is_true(has(git.rows(ctx), "No commits loaded yet"))
    assert.is_true(ctx.store.collapsed["section:graph"] == false)

    git.actions.toggle_section(ctx, "graph")
    assert.is_false(has(git.rows(ctx), "No commits loaded yet"))
  end)

  it("keeps collapse state per repository", function()
    git.actions.toggle_section(ctx, "graph")
    local other = state.get("/tmp/gitvim-other-repo")
    assert.is_nil(other.collapsed["section:graph"])
  end)

  it("follows git.sections when the user reorders or drops one", function()
    config.setup({ git = { sections = { "graph", "scm" }, collapsed = {} } })
    local rows = git.rows(ctx)
    local _, graph = find(rows, "GRAPH")
    local _, scm = find(rows, "SOURCE CONTROL")
    assert.is_true(graph < scm)
    assert.is_false(has(rows, "TIMELINE"))
  end)

  it("shows ahead/behind counts only when the branch has drifted", function()
    assert.is_false(has(git.rows(ctx), "%d+$"))
    repo.ahead, repo.behind = 2, 1
    local row = git.rows(ctx)[1]
    assert.is_truthy(text(row):match("2"))
    assert.is_truthy(text(row):match("1"))
    assert.equals("push", row[5].action)
  end)

  it("says so, rather than drawing chrome, outside a repository", function()
    assert.is_true(has(git.rows({ width = 40, focused = false }), "Not inside a git repository"))
  end)
end)

describe("Buffers tab", function()
  local buffers, created

  before_each(function()
    config.setup({})
    state.reset()
    tabs.reset()
    buffers = tabs.get("buffers")
    buffers.reset()
    created = {}
  end)

  after_each(function()
    for _, buf in ipairs(created) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    state.reset()
    config.setup({})
  end)

  ---@param name string
  ---@return integer
  local function open(name)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, name)
    created[#created + 1] = buf
    return buf
  end

  local function ctx()
    return { repo = nil, store = nil, width = 40, focused = false }
  end

  it("titles the panel and counts what is open", function()
    open("/tmp/gitvim-spec/alpha.lua")
    local row = buffers.rows(ctx())[1]
    assert.equals("OPEN EDITORS", text(row))
    assert.is_table(row.virt)
  end)

  it("lists listed buffers, by name", function()
    local buf = open("/tmp/gitvim-spec/alpha.lua")
    local row = find(buffers.rows(ctx()), "alpha%.lua")
    assert.is_table(row)
    assert.equals("open", row.action)
    assert.equals(buf, row.arg)
  end)

  it("never lists the sidebar's own buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/gitvim-spec/sidebar")
    vim.bo[buf].filetype = "gitvim"
    created[#created + 1] = buf

    assert.is_false(has(buffers.rows(ctx()), "sidebar"))
  end)

  it("hides unlisted buffers unless asked for them", function()
    local buf = open("/tmp/gitvim-spec/scratch.lua")
    vim.bo[buf].buflisted = false
    assert.is_false(has(buffers.rows(ctx()), "scratch%.lua"))

    config.setup({ buffers = { show_unlisted = true } })
    assert.is_true(has(buffers.rows(ctx()), "scratch%.lua"))
  end)

  it("marks the buffer the editor is showing", function()
    local icons = require("gitvim.ui.icons")
    local buf = open("/tmp/gitvim-spec/current.lua")
    vim.api.nvim_set_current_buf(buf)

    local row = find(buffers.rows(ctx()), "current%.lua")
    assert.is_truthy(text(row):match(vim.pesc(icons.get("current"))))
    local marked = false
    for _, chunk in ipairs(row) do
      marked = marked or chunk.hl == "GitVimBufferCurrent"
    end
    assert.is_true(marked, "the current buffer should be highlighted")

    vim.cmd("enew")
  end)

  it("flags unsaved changes", function()
    local buf = open("/tmp/gitvim-spec/dirty.lua")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })

    local row = find(buffers.rows(ctx()), "dirty%.lua")
    assert.is_truthy(text(row):match(vim.pesc(require("gitvim.ui.icons").get("modified"))))

    vim.bo[buf].modified = false
  end)

  it("sorts most-recently-used first when asked", function()
    config.setup({ buffers = { sort = "mru" } })
    local a = open("/tmp/gitvim-spec/a.lua")
    local b = open("/tmp/gitvim-spec/b.lua")

    buffers.touch(a)
    buffers.touch(b)
    local _, first = find(buffers.rows(ctx()), "b%.lua")
    local _, second = find(buffers.rows(ctx()), "a%.lua")
    assert.is_true(first < second)

    buffers.touch(a)
    assert.is_true(
      select(2, find(buffers.rows(ctx()), "a%.lua"))
        < select(2, find(buffers.rows(ctx()), "b%.lua"))
    )
  end)

  it("sorts by name when asked", function()
    config.setup({ buffers = { sort = "name" } })
    open("/tmp/gitvim-spec/zeta.lua")
    open("/tmp/gitvim-spec/alpha.lua")
    assert.is_true(
      select(2, find(buffers.rows(ctx()), "alpha")) < select(2, find(buffers.rows(ctx()), "zeta"))
    )
  end)

  it("groups by directory when asked", function()
    config.setup({ buffers = { group_by_dir = true } })
    open("/tmp/gitvim-spec/nested/deep.lua")
    assert.is_true(has(buffers.rows(ctx()), "nested"))
  end)

  it("refuses to close a buffer with unsaved changes", function()
    local buf = open("/tmp/gitvim-spec/unsaved.lua")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })

    local notify, messages = vim.notify, {}
    vim.notify = function(msg, level)
      messages[#messages + 1] = { msg = msg, level = level }
    end
    buffers.actions.close(ctx(), buf)
    vim.notify = notify

    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.equals(vim.log.levels.WARN, messages[1].level)
    assert.is_truthy(messages[1].msg:match("unsaved"))

    vim.bo[buf].modified = false
  end)

  it("closes a clean buffer", function()
    local buf = open("/tmp/gitvim-spec/clean.lua")
    buffers.actions.close(ctx(), buf)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("says so when nothing is open", function()
    -- Neovim always keeps one buffer alive, so emptiness is `buflisted` being
    -- off everywhere rather than an empty buffer list.
    local was = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].buflisted then
        was[#was + 1] = buf
        vim.bo[buf].buflisted = false
      end
    end

    local rows = buffers.rows(ctx())
    for _, buf in ipairs(was) do
      vim.bo[buf].buflisted = true
    end

    assert.is_true(has(rows, "No open buffers"))
  end)
end)
