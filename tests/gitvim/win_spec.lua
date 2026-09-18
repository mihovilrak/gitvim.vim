--- win.lua: the sidebar's dock window and its scratch buffer.

local win = require("gitvim.ui.win")

--- Windows leak between examples otherwise, and a stray split moves every
--- position we assert on.
local function lone_window()
  vim.cmd("silent! only")
end

describe("Win buffer", function()
  local w

  before_each(function()
    lone_window()
    w = win.new({ name = "gitvim://spec-buf" })
  end)

  after_each(function()
    w:destroy()
    lone_window()
  end)

  it("is an unlisted, unmodifiable scratch buffer of filetype gitvim", function()
    assert.is_true(vim.api.nvim_buf_is_valid(w.buf))
    assert.equals("gitvim", vim.bo[w.buf].filetype)
    assert.equals("nofile", vim.bo[w.buf].buftype)
    assert.is_false(vim.bo[w.buf].modifiable)
    assert.is_false(vim.bo[w.buf].buflisted)
    assert.is_false(vim.bo[w.buf].swapfile)
  end)

  it("outlives the window, so a toggle keeps its contents", function()
    local buf = w.buf
    w:open()
    w:close()
    assert.equals(buf, w.buf)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
  end)

  it("is re-created if something wipes it out", function()
    local buf = w.buf
    vim.api.nvim_buf_delete(buf, { force = true })
    w:open()
    assert.is_not.equals(buf, w.buf)
    assert.equals("gitvim", vim.bo[w.buf].filetype)
  end)
end)

describe("Win:open", function()
  local w

  before_each(function()
    lone_window()
  end)

  after_each(function()
    if w then
      w:destroy()
      w = nil
    end
    lone_window()
  end)

  it("docks full height on the left at the requested width", function()
    w = win.new({ position = "left", width = 34 })
    local id = w:open()

    assert.is_number(id)
    assert.is_true(w:is_open())
    assert.equals(0, vim.api.nvim_win_get_position(id)[2])
    assert.equals(34, vim.api.nvim_win_get_width(id))
    assert.equals(w.buf, vim.api.nvim_win_get_buf(id))
  end)

  it("docks on the right when asked", function()
    w = win.new({ position = "right", width = 30 })
    local id = w:open()
    local col = vim.api.nvim_win_get_position(id)[2]
    assert.is_true(col > 0, "right dock should not start at column 0")
    assert.equals(30, vim.api.nvim_win_get_width(id))
  end)

  it("pins its width, so splits elsewhere cannot steal columns", function()
    w = win.new({ width = 30 })
    local id = w:open()
    assert.is_true(vim.wo[id].winfixwidth)

    vim.cmd("vsplit")
    assert.equals(30, vim.api.nvim_win_get_width(id))
  end)

  it("stays put unless asked to be entered", function()
    local editor = vim.api.nvim_get_current_win()
    w = win.new({})
    w:open()
    assert.equals(editor, vim.api.nvim_get_current_win())
    assert.is_false(w:is_focused())

    w:open(true)
    assert.is_true(w:is_focused())
  end)

  it("is idempotent", function()
    w = win.new({})
    local first = w:open()
    local again = w:open()
    assert.equals(first, again)
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("turns off the decorations that make a dock look like a file", function()
    w = win.new({})
    local id = w:open()
    assert.is_false(vim.wo[id].number)
    assert.is_false(vim.wo[id].wrap)
    assert.is_true(vim.wo[id].cursorline)
    assert.equals("no", vim.wo[id].signcolumn)
    assert.is_truthy(vim.wo[id].winhighlight:match("Normal:GitVimNormal"))
  end)
end)

describe("Win stack mode", function()
  local w

  after_each(function()
    if w then
      w:destroy()
      w = nil
    end
    lone_window()
  end)

  it("splits below whoever already owns the side column", function()
    lone_window()
    -- Stand in for snacks.explorer / neo-tree: a full-height left dock.
    vim.cmd("topleft vsplit")
    local host = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(host, 30)
    local host_row = vim.api.nvim_win_get_position(host)[1]

    w = win.new({ stack = true, position = "left", width = 30 })
    local id = w:open()

    assert.equals(0, vim.api.nvim_win_get_position(id)[2])
    assert.is_true(
      vim.api.nvim_win_get_position(id)[1] > host_row,
      "stacked window should sit below its host"
    )
    -- Sharing the column means sharing its width, not opening a second one.
    assert.equals(vim.api.nvim_win_get_width(host), vim.api.nvim_win_get_width(id))
  end)

  it("opens a column of its own when there is nothing to stack onto", function()
    lone_window()
    -- The only window is the editor, which spans the full width; it is still
    -- a host by position, so `_column_host` finds it and we split it. What
    -- must not happen is a crash or a zero-width window.
    w = win.new({ stack = true, width = 30 })
    local id = w:open()
    assert.is_true(w:is_open())
    assert.is_true(vim.api.nvim_win_get_width(id) > 0)
  end)
end)

describe("Win lifecycle", function()
  local w

  before_each(function()
    lone_window()
    w = win.new({ width = 30 })
  end)

  after_each(function()
    w:destroy()
    lone_window()
  end)

  it("remembers a resized width across a close/open cycle", function()
    local id = w:open()
    vim.api.nvim_win_set_width(id, 55)
    w:close()

    assert.is_false(w:is_open())
    assert.equals(55, w.width)
    assert.equals(55, vim.api.nvim_win_get_width(w:open()))
  end)

  it("notices a window closed behind its back", function()
    local id = w:open()
    vim.api.nvim_win_close(id, true)
    assert.is_false(w:is_open())
    assert.is_nil(w.win)
  end)

  it("closes when toggled while focused, and focuses otherwise", function()
    w:open()
    assert.is_false(w:is_focused())

    w:toggle() -- from the editor: focus, do not close
    assert.is_true(w:is_open())
    assert.is_true(w:is_focused())

    w:toggle() -- from inside: close
    assert.is_false(w:is_open())

    w:toggle() -- closed: open and focus
    assert.is_true(w:is_focused())
  end)

  it("reports the width it would have while closed", function()
    assert.is_false(w:is_open())
    assert.equals(30, w:content_width())
    local id = w:open()
    vim.api.nvim_win_set_width(id, 42)
    assert.equals(42, w:content_width())
  end)

  it("moves the dock to the other side on reconfigure", function()
    w:open()
    assert.equals(0, vim.api.nvim_win_get_position(w.win)[2])

    w:reconfigure({ position = "right" })
    assert.is_true(w:is_open())
    assert.is_true(vim.api.nvim_win_get_position(w.win)[2] > 0)
  end)

  it("resizes in place when only the width changes", function()
    local id = w:open()
    w:reconfigure({ width = 50 })
    assert.equals(id, w.win, "a width change should not reopen the window")
    assert.equals(50, vim.api.nvim_win_get_width(id))
  end)

  it("stores a new width while closed without opening anything", function()
    w:reconfigure({ width = 48 })
    assert.is_false(w:is_open())
    assert.equals(48, w.width)
  end)

  it("destroy() takes the buffer with it", function()
    local buf = w.buf
    w:open()
    w:destroy()
    assert.is_false(w:is_open())
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)
end)
