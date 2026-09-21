--- buffer/signs.lua: theming, statuscolumn composition and hunk actions.

local bridge = require("gitvim.buffer.bridge")
local config = require("gitvim.config")
local signs = require("gitvim.buffer.signs")

local function map(buf, lhs)
  local want = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if vim.api.nvim_replace_termcodes(item.lhs, true, true, true) == want then
      return item
    end
  end
end

describe("buffer.signs", function()
  local old_get_hunks

  before_each(function()
    config.setup({})
    signs.reset()
    old_get_hunks = bridge.get_hunks
  end)

  after_each(function()
    bridge.get_hunks = old_get_hunks
    signs.reset()
  end)

  it("links gitsigns signs to sidebar status colors", function()
    signs.apply_theme()
    assert.equals("GitVimAdded", vim.api.nvim_get_hl(0, { name = "GitSignsAdd", link = true }).link)
    assert.equals(
      "GitVimModified",
      vim.api.nvim_get_hl(0, { name = "GitSignsChangeNr", link = true }).link
    )
    assert.equals(
      "GitVimDeleted",
      vim.api.nvim_get_hl(0, { name = "GitSignsStagedDeleteCul", link = true }).link
    )
  end)

  it("composes with the default and an ordinary custom statuscolumn", function()
    local default = signs.compose("")
    assert.is_truthy(default:find("%%C"))
    assert.is_truthy(default:find("_GitVim.gitvim_statuscolumn"))
    assert.is_truthy(default:find("%%l"))

    local custom = "%C%s%=%{v:lnum}│"
    local composed = signs.compose(custom)
    assert.is_truthy(composed:find("%%C", 1))
    assert.is_truthy(composed:find("%%{v:lnum}", 1))
    assert.equals(1, select(2, composed:gsub("gitvim_statuscolumn", "")))
    assert.equals(composed, signs.compose(composed))
  end)

  it("preserves a Snacks-style dynamic statuscolumn through its expression wrapper", function()
    _G.TestGitVimStatusColumn = function()
      return "%s custom"
    end
    local win = vim.api.nvim_get_current_win()
    local previous = vim.wo[win].statuscolumn
    vim.wo[win].statuscolumn = "%!v:lua.TestGitVimStatusColumn()"
    signs.setup()

    assert.equals("%!v:lua._GitVim.gitvim_statuscolumn_expr()", vim.wo[win].statuscolumn)
    vim.g.statusline_winid = win
    local rendered = _G._GitVim.gitvim_statuscolumn_expr()
    assert.is_truthy(rendered:find("custom", 1, true))
    assert.is_truthy(rendered:find("gitvim_statuscolumn", 1, true))

    signs.reset()
    vim.wo[win].statuscolumn = previous
    _G.TestGitVimStatusColumn = nil
  end)

  it("finds additions, changes, and zero-line deletion hunks", function()
    bridge.get_hunks = function()
      return {
        { added = { start = 3, count = 2 } },
        { added = { start = 9, count = 0 } },
        { added = { start = 0, count = 0 } },
      }
    end
    assert.is_table(signs.hunk_at(0, 1))
    assert.is_table(signs.hunk_at(0, 3))
    assert.is_table(signs.hunk_at(0, 4))
    assert.is_table(signs.hunk_at(0, 9))
    assert.is_nil(signs.hunk_at(0, 8))
  end)

  it("double-clicks only hunk rows and previews in the clicked window", function()
    local old_preview = bridge.preview_hunk_inline
    local called
    bridge.get_hunks = function()
      return { { added = { start = 1, count = 1 } } }
    end
    bridge.preview_hunk_inline = function()
      called = vim.api.nvim_win_get_cursor(0)[1]
    end

    local win = vim.api.nvim_get_current_win()
    assert.is_true(signs.handle_click(win, 1, 2, "l"))
    assert.equals(1, called)
    called = nil
    assert.is_false(signs.handle_click(win, 2, 2, "l"))
    assert.is_nil(called)
    bridge.preview_hunk_inline = old_preview
  end)

  it("stages the clicked hunk through the right-click action menu", function()
    local old_select, old_stage = vim.ui.select, bridge.stage_hunk
    local staged
    bridge.get_hunks = function()
      return { { added = { start = 1, count = 1 } } }
    end
    bridge.stage_hunk = function()
      staged = vim.api.nvim_win_get_cursor(0)[1]
    end
    vim.ui.select = function(items, _, cb)
      for _, item in ipairs(items) do
        if item.label == "Stage hunk" then
          cb(item)
          return
        end
      end
    end

    assert.is_true(signs.handle_click(vim.api.nvim_get_current_win(), 1, 1, "r"))
    assert.equals(1, staged)
    vim.ui.select, bridge.stage_hunk = old_select, old_stage
  end)

  it("offers keyboard parity without replacing an existing buffer mapping", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.keymap.set("n", "<leader>ghs", "<Cmd>let g:kept = 1<CR>", { buffer = buf })
    signs.map_buffer(buf)

    assert.is_table(map(buf, "<leader>ghs"))
    assert.equals("<Cmd>let g:kept = 1<CR>", map(buf, "<leader>ghs").rhs)
    for _, lhs in ipairs({
      "<leader>ghu",
      "<leader>ghr",
      "<leader>ghp",
      "<leader>ghb",
      "<leader>gtb",
      "<leader>ghB",
    }) do
      assert.is_table(map(buf, lhs), lhs)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("renders a real gitsigns sign and current-line blame in a fixture repo", function()
    local fixture = require("fixture").build()
    local gitsigns = require("gitsigns")
    bridge._set_adapter(nil)
    gitsigns.setup({
      current_line_blame = true,
      current_line_blame_opts = { delay = 0, use_focus = false },
      current_line_blame_formatter = "<author>, <author_time:%R> - <summary>",
    })

    vim.cmd.edit(vim.fn.fnameescape(fixture.root .. "/modified.lua"))
    local ready = vim.wait(10000, function()
      return #bridge.get_hunks(0) > 0
    end, 20)
    assert.is_true(ready, "gitsigns did not attach to the modified fixture file")

    local signed = vim.wait(10000, function()
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
        if mark[4] and mark[4].sign_text and mark[4].sign_text ~= "" then
          return true
        end
      end
      return false
    end, 20)
    assert.is_true(signed, "gitsigns attached but did not render a sign")

    vim.cmd.edit(vim.fn.fnameescape(fixture.root .. "/README.md"))
    local blamed = vim.wait(10000, function()
      return bridge.blame_info(0) ~= nil
    end, 20)
    assert.is_true(blamed, "current-line blame was not populated")
    assert.is_string(bridge.blame_info(0).author)

    gitsigns.detach_all()
    vim.cmd.enew({ bang = true })
    fixture:destroy()
  end)
end)
