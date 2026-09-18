--- render.lua: rows -> buffer lines + extmarks, and click resolution.

local render = require("gitvim.ui.render")

--- A throwaway scratch buffer with the sidebar's buffer options, so the
--- renderer is exercised against a `modifiable = false` buffer the way it is
--- in the real dock.
---@return integer
local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = false
  return buf
end

---@param buf integer
---@param ns integer
---@return vim.api.keyset.get_extmark_item[]
local function marks(buf, ns)
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

describe("render.register", function()
  it("returns the v:lua expression a winbar %@ item needs", function()
    local expr = render.register("spec_click", function() end)
    assert.equals("v:lua._GitVim.spec_click", expr)
    assert.is_function(_G._GitVim.spec_click)
  end)

  it("is callable through v:lua, which is the whole point", function()
    local seen
    render.register("spec_click_arg", function(minwid)
      seen = minwid
    end)
    vim.cmd("call v:lua._GitVim.spec_click_arg(7)")
    assert.equals(7, seen)
  end)
end)

describe("render.namespace", function()
  it("is stable per name and distinct across names", function()
    assert.equals(render.namespace("spec_a"), render.namespace("spec_a"))
    assert.is_not.equals(render.namespace("spec_a"), render.namespace("spec_b"))
  end)
end)

describe("Renderer:set", function()
  local buf, r

  before_each(function()
    buf = scratch()
    r = render.new(buf, "spec_render")
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("writes one line per row, concatenating the chunks", function()
    r:set({
      { { text = "SOURCE" }, { text = " " }, { text = "CONTROL" } },
      { { text = "second" } },
    })
    assert.same({ "SOURCE CONTROL", "second" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.same({ "SOURCE CONTROL", "second" }, r:lines())
  end)

  it("leaves the buffer unmodifiable afterwards", function()
    r:set({ { { text = "x" } } })
    assert.is_false(vim.bo[buf].modifiable)
  end)

  it("highlights each chunk over its own byte span", function()
    r:set({ { { text = "ab" }, { text = "cde", hl = "GitVimFile" } } })
    local got = marks(buf, r.ns)
    assert.equals(1, #got)
    assert.equals(2, got[1][3])
    assert.equals("GitVimFile", got[1][4].hl_group)
    assert.equals(5, got[1][4].end_col)
  end)

  it("measures spans in bytes, so multibyte text is not off by a character", function()
    r:set({ { { text = "ünicode" }, { text = "tail", hl = "GitVimDir" } } })
    local got = marks(buf, r.ns)
    assert.equals(#"ünicode", got[1][3])
  end)

  it("applies a row highlight to the whole line", function()
    r:set({ { { text = "row" }, hl = "GitVimHint" } })
    local got = marks(buf, r.ns)
    assert.equals(1, #got)
    assert.equals("GitVimHint", got[1][4].line_hl_group)
  end)

  it("renders virt as right-aligned virtual text, never virt_lines", function()
    r:set({ { { text = "file.lua" }, virt = { { text = "[+]", hl = "GitVimButton" } } } })
    local details = marks(buf, r.ns)[1][4]
    assert.equals("right_align", details.virt_text_pos)
    assert.same({ { "[+]", "GitVimButton" } }, details.virt_text)
    assert.is_nil(details.virt_lines)
  end)

  it("skips empty chunks rather than leaving a zero-width extmark", function()
    r:set({ { { text = "", hl = "GitVimFile" }, { text = "x" } } })
    assert.equals(0, #marks(buf, r.ns))
  end)

  it("does not touch the buffer when nothing changed", function()
    local rows = function()
      return { { { text = "one" } }, { { text = "two" } } }
    end
    r:set(rows())
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    r:set(rows())
    assert.equals(tick, vim.api.nvim_buf_get_changedtick(buf))
  end)

  it("redraws only the rows that changed", function()
    r:set({ { { text = "a" } }, { { text = "b" } }, { { text = "c" } } })
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    r:set({ { { text = "a" } }, { { text = "B" } }, { { text = "c" } } })
    -- One `nvim_buf_set_lines` over the single middle line.
    assert.equals(tick + 1, vim.api.nvim_buf_get_changedtick(buf))
    assert.same({ "a", "B", "c" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("counts a changed highlight as a change, even when the text is identical", function()
    r:set({ { { text = "a", hl = "GitVimFile" } } })
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    r:set({ { { text = "a", hl = "GitVimModified" } } })
    assert.is_true(vim.api.nvim_buf_get_changedtick(buf) > tick)
    assert.equals("GitVimModified", marks(buf, r.ns)[1][4].hl_group)
  end)

  it("does not leave stale marks behind on a partial redraw", function()
    r:set({ { { text = "a", hl = "GitVimFile" } }, { { text = "b", hl = "GitVimFile" } } })
    r:set({ { { text = "a", hl = "GitVimFile" } }, { { text = "b" } } })
    local got = marks(buf, r.ns)
    assert.equals(1, #got)
    assert.equals(0, got[1][2])
  end)

  it("grows and shrinks the buffer with the row count", function()
    r:set({ { { text = "a" } }, { { text = "b" } }, { { text = "c" } } })
    r:set({ { { text = "a" } } })
    assert.same({ "a" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("survives the buffer being wiped out from under it", function()
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.has_no.errors(function()
      r:set({ { { text = "a" } } })
    end)
  end)
end)

describe("Renderer:hit", function()
  local buf, r

  before_each(function()
    buf = scratch()
    r = render.new(buf, "spec_hit")
    r:set({
      {
        { text = "  file.lua", action = "open", arg = "file.lua" },
        { text = " [+]", action = "stage", arg = "file.lua" },
        action = "open",
        arg = "file.lua",
      },
      { { text = "no action here" } },
    })
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("resolves a chunk's own action inside its span", function()
    local action, arg = r:hit(1, #"  file.lua" + 1)
    assert.equals("stage", action)
    assert.equals("file.lua", arg)
  end)

  it("falls back to the row's action outside every chunk span", function()
    assert.equals("open", (r:hit(1, 200)))
  end)

  it("prefers the chunk at the exact first byte of its span", function()
    assert.equals("stage", (r:hit(1, #"  file.lua")))
    assert.equals("open", (r:hit(1, #"  file.lua" - 1)))
  end)

  it("returns nothing for a row with no action at all", function()
    local action, arg, row = r:hit(2, 0)
    assert.is_nil(action)
    assert.is_nil(arg)
    assert.is_table(row)
  end)

  it("returns nothing past the last row", function()
    assert.is_nil((r:hit(99, 0)))
  end)
end)

describe("Renderer accessors", function()
  local buf, r

  before_each(function()
    buf = scratch()
    r = render.new(buf, "spec_access")
    r:set({
      { { text = "one" }, data = { id = 1 } },
      { { text = "two" }, data = { id = 2 } },
    })
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("at() reads a row by 1-based line", function()
    assert.equals(2, r:at(2).data.id)
    assert.is_nil(r:at(3))
  end)

  it("find() returns the first matching line number", function()
    assert.equals(
      2,
      r:find(function(row)
        return row.data and row.data.id == 2
      end)
    )
    assert.is_nil(r:find(function()
      return false
    end))
  end)

  it("rows() hands back what was set", function()
    assert.equals(2, #r:rows())
  end)

  it("clear() empties the buffer and drops every mark", function()
    r:set({ { { text = "x", hl = "GitVimFile" } } })
    r:clear()
    assert.same({ "" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equals(0, #marks(buf, r.ns))
    assert.same({}, r:rows())
  end)
end)
