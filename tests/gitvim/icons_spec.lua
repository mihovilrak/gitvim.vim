--- icons.lua: the nerd-font glyphs and their plain-text stand-ins.

local config = require("gitvim.config")
local icons = require("gitvim.ui.icons")

describe("icons.get", function()
  local had_nerd_font

  before_each(function()
    config.setup({})
    icons.reset()
    had_nerd_font = vim.g.have_nerd_font
  end)

  after_each(function()
    vim.g.have_nerd_font = had_nerd_font
    config.setup({})
    icons.reset()
  end)

  it("returns a glyph for every activity tab", function()
    config.setup({ icons = { style = "nerd" } })
    for _, name in ipairs({ "files", "search", "git", "buffers" }) do
      assert.is_true(#icons.get(name) > 0, name .. " has no glyph")
    end
  end)

  it("falls back to text when the style is ascii", function()
    config.setup({ icons = { style = "ascii" } })
    assert.equals("[/]", icons.get("search"))
    assert.equals(">", icons.chevron(false))
    assert.equals("v", icons.chevron(true))
  end)

  it("drops the tab glyphs entirely in ascii, so the winbar falls back to text", function()
    config.setup({ icons = { style = "ascii" } })
    assert.equals("", icons.get("files"))
    assert.equals("", icons.get("git"))
    assert.equals("", icons.get("buffers"))
  end)

  it("honours icons.enabled = false whatever the style says", function()
    config.setup({ icons = { enabled = false, style = "nerd" } })
    assert.equals("[/]", icons.get("search"))
  end)

  it("trusts vim.g.have_nerd_font under style = auto", function()
    config.setup({ icons = { style = "auto" } })
    vim.g.have_nerd_font = false
    assert.equals("[/]", icons.get("search"))
    vim.g.have_nerd_font = true
    assert.is_not.equals("[/]", icons.get("search"))
  end)

  it("lets an override win over both tables", function()
    config.setup({ icons = { style = "ascii", overrides = { search = "S" } } })
    assert.equals("S", icons.get("search"))
  end)

  it("returns an empty string for a name it does not know", function()
    assert.equals("", icons.get("nonesuch"))
  end)
end)

describe("icons.status", function()
  it("is a letter per status kind, from the config", function()
    config.setup({})
    assert.equals("M", icons.status("modified"))
    assert.equals("!", icons.status("conflict"))
    assert.equals("?", icons.status("nonesuch"))
  end)

  it("is configurable", function()
    config.setup({ icons = { status = { modified = "~" } } })
    assert.equals("~", icons.status("modified"))
    config.setup({})
  end)
end)

describe("icons.file", function()
  after_each(function()
    config.setup({})
    icons.reset()
  end)

  it("renders no icon column at all in ascii mode", function()
    config.setup({ icons = { style = "ascii" } })
    icons.reset()
    local icon, hl = icons.file("/tmp/init.lua", false)
    assert.equals("", icon)
    assert.is_string(hl)
  end)

  it("always returns a glyph and a group with a nerd font", function()
    config.setup({ icons = { style = "nerd" } })
    icons.reset()
    local icon, hl = icons.file("/tmp/init.lua", false)
    assert.is_true(#icon > 0)
    assert.is_string(hl)

    local dir_icon = icons.file("/tmp/src", true)
    assert.is_true(#dir_icon > 0)
  end)
end)
