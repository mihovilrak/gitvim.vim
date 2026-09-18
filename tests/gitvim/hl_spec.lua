--- hl.lua: the GitVim* highlight groups.

local hl = require("gitvim.ui.hl")

describe("hl", function()
  before_each(function()
    hl.apply()
  end)

  it("defines every group it advertises", function()
    for _, name in ipairs(hl.groups()) do
      local got = vim.api.nvim_get_hl(0, { name = name })
      assert.is_true(next(got) ~= nil, name .. " is not defined")
    end
  end)

  it("links rather than hardcoding colors, so colorschemes drive it", function()
    for _, name in ipairs(hl.groups()) do
      local got = vim.api.nvim_get_hl(0, { name = name, link = true })
      assert.is_string(got.link, name .. " is not a link")
    end
  end)

  it("never clobbers a group the user defined first", function()
    vim.api.nvim_set_hl(0, "GitVimModified", { link = "ErrorMsg" })
    hl.apply()
    assert.equals("ErrorMsg", vim.api.nvim_get_hl(0, { name = "GitVimModified", link = true }).link)
    vim.api.nvim_set_hl(0, "GitVimModified", {})
    hl.apply()
  end)

  it("has a group for every status kind", function()
    local groups = {}
    for _, name in ipairs(hl.groups()) do
      groups[name] = true
    end
    for kind, name in pairs(hl.kind) do
      assert.is_true(groups[name], kind .. " maps to an undefined group")
    end
  end)

  it("cycles the lane palette rather than running off the end", function()
    assert.equals("GitVimGraphLane1", hl.lane(1))
    assert.equals("GitVimGraphLane8", hl.lane(hl.LANE_COLORS))
    assert.equals("GitVimGraphLane1", hl.lane(hl.LANE_COLORS + 1))
  end)

  it("re-applies itself after :colorscheme clears everything", function()
    hl.setup()
    vim.cmd.colorscheme("default")
    assert.is_string(vim.api.nvim_get_hl(0, { name = "GitVimTabSel", link = true }).link)
  end)

  it("sorts groups(), so docs generated from it are stable", function()
    local groups = hl.groups()
    local sorted = vim.deepcopy(groups)
    table.sort(sorted)
    assert.same(sorted, groups)
  end)
end)
