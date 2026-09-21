--- The review view: two diff-mode panes, right-aligned hunk buttons, and the
--- stage / revert paths they drive.

local config = require("gitvim.config")
local fixture = require("fixture")
local helpers = require("helpers")
local review = require("gitvim.ui.review")

local await = helpers.await

local TEN = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"

---@param root string
---@param path string
---@param opts? gitvim.review.Opts
---@return gitvim.review.View
local function open(root, path, opts)
  return await(function(done)
    review.open(root, path, opts, done)
  end)
end

---@param buf integer
---@return string[]
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param fix gitvim.Fixture
---@param path string
---@return string
local function worktree(fix, path)
  local fd = assert(io.open(fix.root .. "/" .. path, "rb"))
  local text = fd:read("*a")
  fd:close()
  return text
end

describe("ui.review", function()
  local fix

  before_each(function()
    config.setup({})
    vim.cmd("silent! only")
    fix = fixture.build()
    fix:write("multi.txt", TEN)
    fix:git({ "add", "multi.txt" })
    fix:git({ "commit", "-q", "-m", "multi", "--", "multi.txt" })
    fix:write("multi.txt", (TEN:gsub("^1\n", "one\n"):gsub("\n9\n", "\nnine\n")))
  end)

  after_each(function()
    review.close()
    fix:destroy()
  end)

  it("picks the buttons from what the panes are", function()
    assert.same({ "stage", "revert", "expand" }, review.actions_for(":"))
    assert.same({ "revert", "expand" }, review.actions_for("HEAD"))
    assert.same({ "unstage", "expand" }, review.actions_for("HEAD", ":"))
    assert.same({ "expand" }, review.actions_for("HEAD~1", "HEAD"))
  end)

  it("merges 'diffopt' items by key", function()
    assert.equals(
      "internal,filler,closeoff,linematch:60,algorithm:histogram",
      review.merge_diffopt(
        "internal,filler,closeoff,linematch:40",
        { "linematch:60", "algorithm:histogram" }
      )
    )
  end)

  it("opens the index and the working tree side by side in diff mode", function()
    local v = open(fix.root, "multi.txt")
    assert.equals(v, review.current())
    assert.is_true(vim.wo[v.lwin].diff)
    assert.is_true(vim.wo[v.rwin].diff)
    assert.equals(TEN:gsub("\n$", ""), table.concat(lines(v.lbuf), "\n"))
    assert.same("one", lines(v.rbuf)[1])
    assert.equals(2, #v.hunks)
    assert.truthy(vim.o.diffopt:find("linematch:60", 1, true))
    -- Split: the left pane really is to the left.
    assert.is_true(vim.fn.win_screenpos(v.lwin)[2] < vim.fn.win_screenpos(v.rwin)[2])
  end)

  it("draws the buttons as right-aligned text, never virtual lines", function()
    local v = open(fix.root, "multi.txt")
    local ns = vim.api.nvim_get_namespaces().gitvim_review
    local marks = vim.api.nvim_buf_get_extmarks(v.rbuf, ns, 0, -1, { details = true })
    assert.equals(2, #marks)
    for _, mark in ipairs(marks) do
      assert.equals("right_align", mark[4].virt_text_pos)
      assert.is_nil(mark[4].virt_lines)
    end
    assert.same({ 0, 8 }, { marks[1][2], marks[2][2] })
    -- Neither buffer has virtual lines anywhere.
    for _, buf in ipairs({ v.lbuf, v.rbuf }) do
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        assert.is_nil(mark[4].virt_lines)
      end
    end
  end)

  it("keeps the panes the same height, filler included", function()
    fix:write("multi.txt", (TEN:gsub("\n5\n", "\n5\nextra\nextra\n")))
    local v = open(fix.root, "multi.txt")
    local function height(win)
      return vim.api.nvim_win_text_height(win, {}).all
    end
    assert.equals(height(v.lwin), height(v.rwin))
  end)

  it("maps a click column to the button under it", function()
    local v = open(fix.root, "multi.txt")
    local _, spans, width = review.buttons(v.actions)
    local start = vim.api.nvim_win_get_width(v.rwin) - width
    assert.same({ "stage", 1 }, { review.button_at(1, start + spans[1].from) })
    assert.same({ "revert", 2 }, { review.button_at(9, start + spans[2].to) })
    assert.same({ "expand", 2 }, { review.button_at(9, start + spans[3].from) })
    assert.is_nil(review.button_at(5, start + spans[1].from))
    assert.is_nil(review.button_at(1, 1))
  end)

  it("hides the buttons when hunk_actions is off", function()
    config.setup({ review = { hunk_actions = false } })
    local v = open(fix.root, "multi.txt")
    local ns = vim.api.nvim_get_namespaces().gitvim_review
    assert.same({}, vim.api.nvim_buf_get_extmarks(v.rbuf, ns, 0, -1, {}))
  end)

  it("[+] stages only its hunk and the view follows", function()
    local v = open(fix.root, "multi.txt")
    local err = await(function(done)
      review.act("stage", 2, done)
    end)
    assert.is_nil(err)
    local cached = fix:git({ "diff", "--cached", "-U0", "--", "multi.txt" })
    assert.truthy(cached:find("+nine", 1, true))
    assert.falsy(cached:find("+one", 1, true))
    assert.equals(1, #v.hunks)
    assert.equals("nine", lines(v.lbuf)[9])
  end)

  it("[↩] reverts only its hunk", function()
    config.setup({ scm = { confirm_discard = false } })
    local v = open(fix.root, "multi.txt")
    local err = await(function(done)
      review.act("revert", 1, done)
    end)
    assert.is_nil(err)
    assert.equals(TEN:gsub("\n9\n", "\nnine\n"), worktree(fix, "multi.txt"))
    assert.equals(1, #v.hunks)
  end)

  it("unstages a hunk from a HEAD vs index review", function()
    fix:git({ "add", "multi.txt" })
    local v = open(fix.root, "multi.txt", { left_rev = "HEAD", right_rev = ":" })
    assert.same({ "unstage", "expand" }, v.actions)
    await(function(done)
      review.act("unstage", 1, done)
    end)
    local cached = fix:git({ "diff", "--cached", "-U0", "--", "multi.txt" })
    assert.falsy(cached:find("+one", 1, true))
    assert.truthy(cached:find("+nine", 1, true))
  end)

  it("moves between hunks with ]h and [h", function()
    local v = open(fix.root, "multi.txt")
    vim.api.nvim_set_current_win(v.rwin)
    vim.api.nvim_win_set_cursor(v.rwin, { 1, 0 })
    assert.is_true(review.jump(1))
    assert.equals(9, vim.api.nvim_win_get_cursor(v.rwin)[1])
    assert.is_false(review.jump(1))
    assert.is_true(review.jump(-1))
    assert.equals(1, vim.api.nvim_win_get_cursor(v.rwin)[1])
    -- The keymaps are there, in both panes.
    for _, buf in ipairs({ v.lbuf, v.rbuf }) do
      vim.api.nvim_buf_call(buf, function()
        for _, lhs in ipairs({ "]h", "[h", "s", "x", "o", "q", "<LeftRelease>" }) do
          assert.equals(1, vim.fn.maparg(lhs, "n", false, true).buffer, lhs)
        end
      end)
    end
  end)

  it("handles a deleted file", function()
    local v = open(fix.root, "deleted.lua")
    assert.same({ "return 2" }, lines(v.lbuf))
    assert.equals(1, #v.hunks)
    assert.truthy(vim.wo[v.rwin].winbar:find("(absent)", 1, true))
  end)

  it("handles an untracked file", function()
    local v = open(fix.root, "spaced ünicode.txt")
    assert.is_true(v.left.missing)
    assert.same({ "paths are hard" }, lines(v.rbuf))
    assert.equals(1, #v.hunks)
  end)

  it("handles a rename between revisions", function()
    -- HEAD~4 is the initial commit: multi.txt and the merge sit on top.
    local v = open(
      fix.root,
      "docs/guide.md",
      { left_rev = "HEAD~4", right_rev = "HEAD", left_path = "GUIDE.md" }
    )
    assert.same({ "guide, line one", "guide, line two" }, lines(v.lbuf))
    assert.equals(3, #lines(v.rbuf))
    assert.same({ "expand" }, v.actions)
  end)

  it("shows a binary file without diffing it", function()
    local fd = assert(io.open(fix.root .. "/blob.bin", "wb"))
    fd:write("\0\1\2binary")
    fd:close()
    local v = open(fix.root, "blob.bin")
    assert.same({}, v.hunks)
    assert.truthy(lines(v.rbuf)[1]:find("Binary", 1, true))
  end)

  it("puts the editor window and 'diffopt' back on close", function()
    local before = vim.o.diffopt
    local win = require("gitvim.ui.sidebar").editor_window()
    local buf = vim.api.nvim_win_get_buf(win)
    local v = open(fix.root, "multi.txt")
    review.close()
    assert.is_nil(review.current())
    assert.equals(before, vim.o.diffopt)
    assert.is_false(vim.api.nvim_win_is_valid(v.lwin))
    assert.equals(buf, vim.api.nvim_win_get_buf(win))
    assert.is_false(vim.wo[win].diff)
  end)

  it("closes when a pane is closed", function()
    local v = open(fix.root, "multi.txt")
    vim.api.nvim_win_close(v.lwin, true)
    vim.wait(1000, function()
      return review.current() == nil
    end)
    assert.is_nil(review.current())
  end)

  it("opens from a SOURCE CONTROL row", function()
    local scm = require("gitvim.ui.sections.scm")
    local ctx = { repo = { root = fix.root } }
    local entry = { path = "staged.lua", group = "staged", x = "A", y = "M", kind = "added" }
    scm.actions.open(ctx, "staged.lua", { data = entry })
    vim.wait(5000, function()
      local v = review.current()
      return v ~= nil and #v.hunks > 0
    end)
    local v = assert(review.current())
    assert.equals("HEAD", v.left_rev)
    assert.equals(":", v.right_rev)
    assert.same({ "return 'staged'" }, lines(v.rbuf))
  end)
end)
