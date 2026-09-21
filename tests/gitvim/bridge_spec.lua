--- buffer/bridge.lua: the isolated, optional gitsigns boundary.

local bridge = require("gitvim.buffer.bridge")

describe("buffer.bridge", function()
  after_each(function()
    bridge._set_adapter(nil)
  end)

  it("degrades gracefully when gitsigns is absent", function()
    bridge._set_adapter(false)
    assert.is_false(bridge.available())
    assert.same({}, bridge.get_hunks(0))
    assert.is_false(bridge.stage_hunk())
    assert.is_false(bridge.preview_hunk_inline())
    assert.is_nil(bridge.toggle_blame())
  end)

  it("forwards the documented API without exposing gitsigns elsewhere", function()
    local calls = {}
    bridge._set_adapter({
      setup = function(opts)
        calls.setup = opts
      end,
      get_hunks = function(buf)
        calls.buf = buf
        return { { head = "@@" } }
      end,
      statuscolumn = function(buf, lnum)
        calls.statuscolumn = { buf, lnum }
        return "┃"
      end,
      stage_hunk = function(range)
        calls.stage = range
      end,
      reset_hunk = function(range)
        calls.reset = range
      end,
      undo_stage_hunk = function()
        calls.undo = true
      end,
      preview_hunk_inline = function()
        calls.preview = true
      end,
      blame_line = function()
        calls.blame = true
      end,
      toggle_current_line_blame = function(value)
        calls.toggle = value
        return value
      end,
      nav_hunk = function(direction)
        calls.nav = direction
      end,
    })

    assert.is_true(bridge.setup({ current_line_blame = true }))
    assert.equals("@@", bridge.get_hunks(42)[1].head)
    assert.equals("┃", bridge.statuscolumn(42, 3))
    assert.is_true(bridge.stage_hunk({ 2, 4 }))
    assert.is_true(bridge.reset_hunk({ 5, 6 }))
    assert.is_true(bridge.undo_stage_hunk())
    assert.is_true(bridge.preview_hunk_inline())
    assert.is_true(bridge.blame_line())
    assert.is_true(bridge.toggle_blame(true))
    assert.is_true(bridge.nav_hunk("next"))

    assert.same({ current_line_blame = true }, calls.setup)
    assert.equals(42, calls.buf)
    assert.same({ 42, 3 }, calls.statuscolumn)
    assert.same({ 2, 4 }, calls.stage)
    assert.same({ 5, 6 }, calls.reset)
    assert.equals("next", calls.nav)
  end)
end)
