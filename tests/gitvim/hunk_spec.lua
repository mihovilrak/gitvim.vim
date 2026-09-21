--- Hunk-level reads, stage/unstage and revert, confirmed with git directly.

local fixture = require("fixture")
local helpers = require("helpers")
local hunk = require("gitvim.git.hunk")

local await = helpers.await

local TEN = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"

---@param root string
---@param rev? string
---@param path string
---@return gitvim.hunk.Side
local function read(root, rev, path)
  return await(function(done)
    hunk.read(root, rev, path, done)
  end)
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

describe("git.hunk", function()
  describe("parse / serialize", function()
    it("round-trips LF, CRLF and a missing final newline", function()
      for _, text in ipairs({ "a\nb\n", "a\r\nb\r\n", "a\nb", "a\r\nb", "", "x\n" }) do
        local side = hunk.parse(text)
        assert.equals(text, hunk.serialize(side.lines, side.eol, side.noeol))
      end
      assert.same({ "a", "b" }, hunk.parse("a\r\nb\r\n").lines)
      assert.equals("\r\n", hunk.parse("a\r\nb\r\n").eol)
      assert.is_true(hunk.parse("a\nb").noeol)
    end)

    it("keeps the CRs of a mixed-ending file as content", function()
      local side = hunk.parse("a\r\nb\n")
      assert.equals("\n", side.eol)
      assert.same({ "a\r", "b" }, side.lines)
    end)

    it("flags a NUL byte as binary", function()
      assert.is_true(hunk.parse("abc\0def").binary)
    end)
  end)

  describe("compute / range", function()
    it("finds each change as its own hunk", function()
      local a, b =
        hunk.parse(TEN), hunk.parse(TEN:gsub("2\n", "two\n", 1):gsub("\n8\n", "\neight\n"))
      local hunks = hunk.compute(a, b)
      assert.equals(2, #hunks)
      assert.same({ a_start = 2, a_count = 1, b_start = 2, b_count = 1 }, hunks[1])
      assert.same({ 8, 8 }, { hunk.range(hunks[2], "b") })
    end)

    it("places a pure insertion or deletion on the line it follows", function()
      local hunks = hunk.compute(hunk.parse("a\nb\nc\n"), hunk.parse("a\nc\n"))
      assert.same({ 2, 2 }, { hunk.range(hunks[1], "a") })
      assert.same({ 1, 1 }, { hunk.range(hunks[1], "b") })
      local top = hunk.compute(hunk.parse(""), hunk.parse("x\n"))
      assert.same({ 1, 1 }, { hunk.range(top[1], "a") })
    end)

    it("has no hunks for a binary side", function()
      assert.same({}, hunk.compute(hunk.parse("a\n"), hunk.parse("\0")))
    end)
  end)

  describe("against the fixture", function()
    local fix

    before_each(function()
      fix = fixture.build()
      fix:write("multi.txt", TEN)
      fix:git({ "add", "multi.txt" })
      fix:git({ "commit", "-q", "-m", "multi", "--", "multi.txt" })
      fix:write("multi.txt", (TEN:gsub("^1\n", "one\n"):gsub("\n9\n", "\nnine\n")))
    end)

    after_each(function()
      fix:destroy()
    end)

    it("reads the index, a revision, the worktree and absent paths", function()
      assert.same({ "return 'staged'" }, read(fix.root, hunk.INDEX, "staged.lua").lines)
      assert.same({ "return 'staged, then modified'" }, read(fix.root, nil, "staged.lua").lines)
      assert.is_true(read(fix.root, "HEAD", "staged.lua").missing)
      assert.is_true(read(fix.root, nil, "deleted.lua").missing)
      assert.same({ "return 2" }, read(fix.root, hunk.INDEX, "deleted.lua").lines)
      assert.equals("directory", read(fix.root, "HEAD", "docs").special)
      assert.is_true(read(fix.root, "HEAD", "no/such/file").missing)
    end)

    it("stages only the chosen hunk", function()
      local a, b = read(fix.root, hunk.INDEX, "multi.txt"), read(fix.root, nil, "multi.txt")
      local hunks = hunk.compute(a, b)
      assert.equals(2, #hunks)
      local err = await(function(done)
        hunk.stage(fix.root, "multi.txt", a, b, hunks[2], done)
      end)
      assert.is_nil(err)
      local cached = fix:git({ "diff", "--cached", "-U0", "--", "multi.txt" })
      assert.truthy(cached:find("+nine", 1, true))
      assert.falsy(cached:find("+one", 1, true))
      local unstaged = fix:git({ "diff", "-U0", "--", "multi.txt" })
      assert.truthy(unstaged:find("+one", 1, true))
      assert.falsy(unstaged:find("+nine", 1, true))
    end)

    it("unstages only the chosen hunk", function()
      fix:git({ "add", "multi.txt" })
      local a, b = read(fix.root, "HEAD", "multi.txt"), read(fix.root, hunk.INDEX, "multi.txt")
      local hunks = hunk.compute(a, b)
      local err = await(function(done)
        hunk.unstage(fix.root, "multi.txt", a, b, hunks[1], "HEAD", done)
      end)
      assert.is_nil(err)
      local cached = fix:git({ "diff", "--cached", "-U0", "--", "multi.txt" })
      assert.falsy(cached:find("+one", 1, true))
      assert.truthy(cached:find("+nine", 1, true))
    end)

    it("reverts only the chosen hunk", function()
      local a, b = read(fix.root, hunk.INDEX, "multi.txt"), read(fix.root, nil, "multi.txt")
      local hunks = hunk.compute(a, b)
      local err = await(function(done)
        hunk.revert(fix.root, "multi.txt", a, b, hunks[1], done)
      end)
      assert.is_nil(err)
      assert.equals(TEN:gsub("\n9\n", "\nnine\n"), worktree(fix, "multi.txt"))
    end)

    it("keeps CRLF endings when reverting", function()
      fix:write("crlf.txt", "a\r\nb\r\nc\r\n")
      fix:git({ "add", "crlf.txt" })
      fix:write("crlf.txt", "a\r\nB\r\nc\r\n")
      local a, b = read(fix.root, hunk.INDEX, "crlf.txt"), read(fix.root, nil, "crlf.txt")
      local hunks = hunk.compute(a, b)
      assert.equals(1, #hunks)
      await(function(done)
        hunk.revert(fix.root, "crlf.txt", a, b, hunks[1], done)
      end)
      assert.equals("a\r\nb\r\nc\r\n", worktree(fix, "crlf.txt"))
    end)

    it("stages a deletion as a removal from the index", function()
      local a, b = read(fix.root, hunk.INDEX, "deleted.lua"), read(fix.root, nil, "deleted.lua")
      local hunks = hunk.compute(a, b)
      assert.equals(1, #hunks)
      await(function(done)
        hunk.stage(fix.root, "deleted.lua", a, b, hunks[1], done)
      end)
      assert.truthy(fix:git({ "status", "--porcelain" }):find("D  deleted.lua", 1, true))
    end)

    it("reverts a deletion by restoring the file", function()
      local a, b = read(fix.root, hunk.INDEX, "deleted.lua"), read(fix.root, nil, "deleted.lua")
      await(function(done)
        hunk.revert(fix.root, "deleted.lua", a, b, hunk.compute(a, b)[1], done)
      end)
      assert.equals("return 2\n", worktree(fix, "deleted.lua"))
    end)

    it("stages an untracked file and reverting it removes the file", function()
      local path = "spaced ünicode.txt"
      local a, b = read(fix.root, hunk.INDEX, path), read(fix.root, nil, path)
      assert.is_true(a.missing)
      local hunks = hunk.compute(a, b)
      await(function(done)
        hunk.stage(fix.root, path, a, b, hunks[1], done)
      end)
      assert.equals("paths are hard\n", fix:git({ "show", ":" .. path }))

      fix:git({ "rm", "--cached", "-q", "--", path })
      await(function(done)
        hunk.revert(fix.root, path, a, b, hunks[1], done)
      end)
      assert.is_nil(vim.uv.fs_stat(fix.root .. "/" .. path))
    end)

    it("unstaging the only hunk of an added file un-adds it", function()
      local a, b = read(fix.root, "HEAD", "staged.lua"), read(fix.root, hunk.INDEX, "staged.lua")
      await(function(done)
        hunk.unstage(fix.root, "staged.lua", a, b, hunk.compute(a, b)[1], "HEAD", done)
      end)
      assert.truthy(fix:git({ "status", "--porcelain" }):find("?? staged.lua", 1, true))
    end)

    it("keeps an executable bit when staging", function()
      -- `--chmod` would re-hash the worktree file; change the mode alone.
      local sha = fix:sha(":multi.txt")
      fix:git({ "update-index", "--cacheinfo", "100755," .. sha .. ",multi.txt" })
      local a, b = read(fix.root, hunk.INDEX, "multi.txt"), read(fix.root, nil, "multi.txt")
      await(function(done)
        hunk.stage(fix.root, "multi.txt", a, b, hunk.compute(a, b)[1], done)
      end)
      assert.truthy(fix:git({ "ls-files", "-s", "multi.txt" }):find("^100755"))
    end)
  end)
end)
