--- buffer/blame.lua: toggling and graph cross-navigation.

local blame = require("gitvim.buffer.blame")
local bridge = require("gitvim.buffer.bridge")

describe("buffer.blame", function()
  it("delegates the current-line blame toggle", function()
    local old = bridge.toggle_blame
    local got
    bridge.toggle_blame = function(value)
      got = value
      return true
    end
    assert.is_true(blame.toggle(true))
    assert.is_true(got)
    bridge.toggle_blame = old
  end)

  it("expands and reveals the blamed commit in GRAPH", function()
    local gitvim = require("gitvim")
    local sidebar = require("gitvim.ui.sidebar")
    local old_info = bridge.blame_info
    local old_refresh = gitvim.refresh
    local old_open, old_reveal = sidebar.open, sidebar.reveal
    local opened, revealed
    local store = { collapsed = {} }

    bridge.blame_info = function()
      return { sha = "1234567890abcdef" }
    end
    gitvim.refresh = function(_, cb)
      cb(nil, store)
    end
    sidebar.open = function(tab)
      opened = tab
    end
    sidebar.reveal = function(action, arg)
      revealed = { action, arg }
    end

    blame.open_commit(vim.api.nvim_get_current_buf())
    assert.equals("1234567890abcdef", store.graph_commit)
    assert.is_false(store.collapsed["section:graph"])
    assert.equals("git", opened)
    assert.same({ "toggle_section", "graph" }, revealed)

    bridge.blame_info = old_info
    gitvim.refresh = old_refresh
    sidebar.open, sidebar.reveal = old_open, old_reveal
  end)
end)
