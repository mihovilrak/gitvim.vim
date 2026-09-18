--- The sidebar: one dock, four tabs, and the wiring between them.
---
--- Keymaps are exercised by calling the mapping's own callback rather than by
--- feeding keys: `nvim_feedkeys` needs an event loop that a headless busted run
--- does not reliably pump, and the callback is the same function the user's
--- keypress would reach.

local config = require("gitvim.config")
local fixture = require("fixture")
local helpers = require("helpers")
local icons = require("gitvim.ui.icons")
local repo_mod = require("gitvim.git.repo")
local sidebar = require("gitvim.ui.sidebar")
local state = require("gitvim.state")
local tabs = require("gitvim.ui.tabs")

local await = helpers.await

---@return integer?
local function sidebar_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "gitvim" then
      return win
    end
  end
  return nil
end

---@return integer
local function sidebar_buf()
  local win = sidebar_win()
  assert.is_number(win, "the sidebar window should be open")
  return vim.api.nvim_win_get_buf(win)
end

---@return string[]
local function lines()
  return vim.api.nvim_buf_get_lines(sidebar_buf(), 0, -1, false)
end

---@param pattern string
---@return integer?  1-based line
local function line_matching(pattern)
  for i, line in ipairs(lines()) do
    if line:match(pattern) then
      return i
    end
  end
  return nil
end

--- The callback of a buffer-local normal-mode mapping, found by lhs.
---
--- Both sides go through `nvim_replace_termcodes` so the lookup works whether
--- the API hands back `<Tab>` or a literal tab character.
---@return function?
local function keymap(buf, lhs)
  local want = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == want then
      return map.callback
    end
  end
  return nil
end

local function press(lhs)
  local buf = sidebar_buf()
  local cb = keymap(buf, lhs)
  assert.is_function(cb, "no mapping for " .. lhs)
  cb()
end

--- Collect what `vim.notify` is told while `fn` runs.
---@return table[]
local function notifications(fn)
  local notify, messages = vim.notify, {}
  vim.notify = function(msg, level)
    messages[#messages + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return messages
end

--- A fixture repository, detected and made active, so the tabs the sidebar
--- draws have something to draw.
---@return table  the fixture, for `:destroy()`
local function repo()
  local fix = fixture.build()
  local _, found = await(function(done)
    repo_mod.detect(fix.root, done)
  end)
  repo_mod.set_active(found.root)
  return fix
end

--- A window that is not the sidebar, to stand in for the user's editor.
---@return integer
local function other_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= sidebar_win() then
      return win
    end
  end
  error("no editor window")
end

describe("sidebar.open", function()
  local fix

  before_each(function()
    config.setup({})
    state.reset()
    repo_mod.reset()
    vim.cmd("silent! only")
    fix = repo()
  end)

  after_each(function()
    sidebar.reset()
    fix:destroy()
    state.reset()
    repo_mod.reset()
    config.setup({})
  end)

  it("docks a focused gitvim window on the default tab", function()
    sidebar.open()

    assert.is_true(sidebar.is_open())
    assert.equals("git", sidebar.tab())
    assert.equals(sidebar_win(), vim.api.nvim_get_current_win())
    assert.equals("gitvim", vim.bo[sidebar_buf()].filetype)
    assert.equals(0, vim.api.nvim_win_get_position(sidebar_win())[2])
  end)

  it("opens on a named tab when asked", function()
    sidebar.open("files")
    assert.equals("files", sidebar.tab())
  end)

  it("opens once, however often it is asked", function()
    sidebar.open()
    sidebar.open()
    sidebar.open("buffers")
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("shows the active tab's rows", function()
    sidebar.open("buffers")
    assert.is_truthy(lines()[1]:match("OPEN EDITORS"))
  end)

  it("replaces the content when the tab changes", function()
    sidebar.open("buffers")
    sidebar.select_tab("search")
    assert.is_number(line_matching("Pattern"), "the search form should be showing")
    assert.is_nil(line_matching("OPEN EDITORS"))
  end)

  it("reports a tab that errors instead of leaving a stale panel", function()
    sidebar.open("buffers")
    local buffers = tabs.get("buffers")
    local rows = buffers.rows
    buffers.rows = function()
      error("boom")
    end

    local messages = notifications(function()
      sidebar.redraw()
    end)
    buffers.rows = rows

    assert.equals(1, #messages)
    assert.equals(vim.log.levels.ERROR, messages[1].level)
    assert.is_truthy(messages[1].msg:match("boom"))
    assert.is_number(line_matching("errored"))
  end)
end)

describe("sidebar winbar", function()
  before_each(function()
    config.setup({})
    vim.cmd("silent! only")
  end)

  after_each(function()
    sidebar.reset()
    icons.reset()
    config.setup({})
  end)

  ---@return string
  local function winbar()
    return vim.wo[sidebar_win()].winbar
  end

  it("gives every tab its own click region", function()
    sidebar.open()
    local wb = winbar()
    local regions = select(2, wb:gsub("@v:lua%._GitVim%.sidebar_tab@", ""))
    assert.equals(#config.options.sidebar.tabs, regions)
  end)

  it("labels Search with its icon alone, and the rest with text", function()
    config.setup({ icons = { style = "nerd" } })
    icons.reset()
    sidebar.open()
    local wb = winbar()

    assert.is_truthy(wb:find(icons.get("files") .. "%#GitVimTab# Files", 1, true))
    assert.is_truthy(wb:find("Git", 1, true))
    assert.is_truthy(wb:find("Buffers", 1, true))
    assert.is_truthy(wb:find(icons.get("search"), 1, true))
    assert.is_nil(wb:find("Search", 1, true), "the Search tab is icon-only")
  end)

  it("falls back to text when there is no nerd font", function()
    config.setup({ icons = { style = "ascii" } })
    icons.reset()
    sidebar.open()
    local wb = winbar()

    assert.is_truthy(wb:find(" Files ", 1, true))
    -- Search has no title to fall back to, so its ascii stand-in is the label.
    assert.is_truthy(wb:find(icons.get("search"), 1, true))
  end)

  it("marks the tab that is showing", function()
    sidebar.open("git")
    -- git is the third entry in sidebar.tabs, hence the %3@ click id.
    assert.is_truthy(winbar():find("%#GitVimTabSel#%3@", 1, true))
    sidebar.select_tab("files")
    assert.is_truthy(winbar():find("%#GitVimTabSel#%1@", 1, true))
  end)

  it("switches tabs when a winbar region is clicked", function()
    sidebar.open("git")
    _G._GitVim.sidebar_tab(1)
    assert.equals("files", sidebar.tab())
    _G._GitVim.sidebar_tab(4)
    assert.equals("buffers", sidebar.tab())
  end)

  it("ignores a click on a region that is not a tab", function()
    sidebar.open("git")
    _G._GitVim.sidebar_tab(9)
    assert.equals("git", sidebar.tab())
  end)
end)

describe("sidebar tab switching", function()
  local fix

  before_each(function()
    config.setup({})
    state.reset()
    repo_mod.reset()
    vim.cmd("silent! only")
    fix = repo()
    sidebar.open("git")
  end)

  after_each(function()
    sidebar.reset()
    fix:destroy()
    state.reset()
    repo_mod.reset()
    config.setup({})
  end)

  it("cycles forward and backward, wrapping at the ends", function()
    sidebar.cycle(1)
    assert.equals("buffers", sidebar.tab())
    sidebar.cycle(1)
    assert.equals("files", sidebar.tab())
    sidebar.cycle(-1)
    assert.equals("buffers", sidebar.tab())
  end)

  it("cycles from <Tab> and <S-Tab> too", function()
    press("<Tab>")
    assert.equals("buffers", sidebar.tab())
    press("<S-Tab>")
    assert.equals("git", sidebar.tab())
  end)

  it("reaches each tab from its number key", function()
    for i, name in ipairs(config.options.sidebar.tabs) do
      press(tostring(i))
      assert.equals(name, sidebar.tab())
    end
  end)

  it("refuses a tab that does not exist, loudly", function()
    local messages = notifications(function()
      sidebar.select_tab("nonesuch")
    end)
    assert.equals(1, #messages)
    assert.equals(vim.log.levels.ERROR, messages[1].level)
    assert.is_truthy(messages[1].msg:match("nonesuch"))
    assert.equals("git", sidebar.tab())
  end)

  it("swaps the active tab's own keymaps in and out", function()
    assert.is_nil(keymap(sidebar_buf(), "<M-c>"), "search keys should not leak into git")
    sidebar.select_tab("search")
    assert.is_function(keymap(sidebar_buf(), "<M-c>"))
    sidebar.select_tab("git")
    assert.is_nil(keymap(sidebar_buf(), "<M-c>"))
  end)

  it("keeps the shared keymaps across a switch", function()
    for _, lhs in ipairs({ "<CR>", "q", "R", "<Tab>", "<LeftRelease>" }) do
      assert.is_function(keymap(sidebar_buf(), lhs), lhs .. " should be mapped")
    end
    sidebar.select_tab("search")
    assert.is_function(keymap(sidebar_buf(), "<CR>"))
  end)

  it("puts the cursor back where each tab left it", function()
    local win = sidebar_win()
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    sidebar.select_tab("buffers")
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    sidebar.select_tab("git")
    assert.equals(3, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("does not move the cursor on a plain redraw", function()
    local win = sidebar_win()
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    sidebar.redraw()
    assert.equals(2, vim.api.nvim_win_get_cursor(win)[1])
  end)
end)

describe("sidebar actions", function()
  local fix, root

  before_each(function()
    config.setup({})
    state.reset()
    repo_mod.reset()
    vim.cmd("silent! only")
    fix = repo()
    root = repo_mod.active().root
    sidebar.open("git")
  end)

  after_each(function()
    sidebar.reset()
    fix:destroy()
    state.reset()
    repo_mod.reset()
    config.setup({})
  end)

  it("runs the row's own action on <CR>", function()
    local lnum = line_matching("GRAPH")
    assert.is_number(lnum, "the GRAPH section header should be showing")
    vim.api.nvim_win_set_cursor(sidebar_win(), { lnum, 0 })
    press("<CR>")

    assert.is_true(state.get(root).collapsed["section:graph"] == false)
    assert.is_number(line_matching("No commits loaded yet"), "the section should have opened")
  end)

  it("resolves a click to the chunk under the mouse", function()
    local lnum = line_matching("TIMELINE")
    assert.is_number(lnum)
    vim.api.nvim_win_set_cursor(sidebar_win(), { lnum, 0 })
    press("<2-LeftMouse>")
    assert.is_true(state.get(root).collapsed["section:timeline"] == false)
  end)

  it("reports a key bound to an action no tab provides", function()
    local git = tabs.get("git")
    git.keys["X"] = "nope"
    sidebar.select_tab("files")
    sidebar.select_tab("git")

    local messages = notifications(function()
      press("X")
    end)
    git.keys["X"] = nil

    assert.equals(1, #messages)
    assert.equals(vim.log.levels.WARN, messages[1].level)
    assert.is_truthy(messages[1].msg:match("no action 'nope'"))
  end)

  it("survives an action that throws, and says which one", function()
    local git = tabs.get("git")
    git.actions.boom = function()
      error("kaboom")
    end
    git.keys["X"] = "boom"
    sidebar.select_tab("files")
    sidebar.select_tab("git")

    local messages = notifications(function()
      press("X")
    end)
    git.keys["X"] = nil
    git.actions.boom = nil

    assert.equals(1, #messages)
    assert.equals(vim.log.levels.ERROR, messages[1].level)
    assert.is_truthy(messages[1].msg:match("boom"))
    assert.is_true(sidebar.is_open(), "a failed action should not take the sidebar down")
  end)

  it("closes on q", function()
    press("q")
    assert.is_false(sidebar.is_open())
  end)
end)

describe("sidebar and the editor window", function()
  local path

  before_each(function()
    config.setup({})
    vim.cmd("silent! only")
    path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "hello" }, path)
    sidebar.open("files")
  end)

  after_each(function()
    sidebar.reset()
    vim.fn.delete(path)
    config.setup({})
  end)

  it("opens a file beside itself, never inside itself", function()
    local dock = sidebar_win()
    sidebar.open_file(path)

    local win = vim.api.nvim_get_current_win()
    assert.are_not.equals(dock, win)
    assert.equals(vim.fs.normalize(path), vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
    assert.is_true(sidebar.is_open())
    assert.equals("gitvim", vim.bo[vim.api.nvim_win_get_buf(dock)].filetype)
  end)

  it("shows an existing buffer in the editor window", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "gitvim-spec-target")
    sidebar.open_buf(buf)

    assert.equals(buf, vim.api.nvim_get_current_buf())
    assert.are_not.equals(sidebar_win(), nil)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("makes a window when the sidebar is the only one left", function()
    vim.cmd("silent! only")
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))

    sidebar.open_file(path)
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.equals(vim.fs.normalize(path), vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
  end)

  it("gets out of the way when close_on_open is set", function()
    config.setup({ sidebar = { close_on_open = true } })
    sidebar.open_file(path)
    assert.is_false(sidebar.is_open())
  end)

  it("reuses the window the user came from", function()
    local editor = other_win()
    vim.api.nvim_set_current_win(editor)
    sidebar.open()
    sidebar.open_file(path)
    assert.equals(editor, vim.api.nvim_get_current_win())
  end)
end)

describe("sidebar lifecycle", function()
  before_each(function()
    config.setup({})
    vim.cmd("silent! only")
  end)

  after_each(function()
    sidebar.reset()
    config.setup({})
  end)

  it("toggles open, focused, closed", function()
    sidebar.toggle()
    assert.is_true(sidebar.is_open())

    -- Open but not current: toggling focuses rather than closing, so a stray
    -- <leader>g from the editor never hides what you were looking at.
    vim.api.nvim_set_current_win(other_win())
    sidebar.toggle()
    assert.is_true(sidebar.is_open())
    assert.equals(sidebar_win(), vim.api.nvim_get_current_win())

    sidebar.toggle()
    assert.is_false(sidebar.is_open())
  end)

  it("keeps its buffer, its tab and its cursor across a close", function()
    sidebar.open("buffers")
    local buf = sidebar_buf()
    vim.api.nvim_win_set_cursor(sidebar_win(), { 2, 0 })
    sidebar.close()

    assert.is_false(sidebar.is_open())
    assert.is_true(vim.api.nvim_buf_is_valid(buf))

    sidebar.open()
    assert.equals(buf, sidebar_buf())
    assert.equals("buffers", sidebar.tab())
    assert.equals(2, vim.api.nvim_win_get_cursor(sidebar_win())[1])
  end)

  it("moves the dock when the position changes", function()
    sidebar.open()
    assert.equals(0, vim.api.nvim_win_get_position(sidebar_win())[2])

    config.setup({ sidebar = { position = "right" } })
    sidebar.reconfigure()
    assert.is_true(vim.api.nvim_win_get_position(sidebar_win())[2] > 0)
  end)

  it("redraws and closes harmlessly when it is not open", function()
    sidebar.redraw()
    sidebar.close()
    assert.is_false(sidebar.is_open())
  end)

  it("forgets everything on reset", function()
    sidebar.open("search")
    local buf = sidebar_buf()
    sidebar.reset()

    assert.is_false(sidebar.is_open())
    assert.is_nil(sidebar.tab())
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)
end)
