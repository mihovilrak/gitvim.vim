--- Stage, unstage and discard, confirmed with `git status` run directly.

local fixture = require("fixture")
local helpers = require("helpers")
local stage = require("gitvim.git.stage")

local await = helpers.await

--- `git status` as path -> XY, straight from git rather than through gitvim.
---@param fix gitvim.Fixture
---@return table<string, string>
local function porcelain(fix)
  local out = {}
  for _, record in
    ipairs(vim.split(fix:git({ "status", "--porcelain", "-z" }), "\0", { trimempty = true }))
  do
    out[record:sub(4)] = record:sub(1, 2)
  end
  return out
end

---@param path string
---@param group gitvim.status.Group
---@return gitvim.status.Entry
local function entry(path, group)
  return { path = path, group = group, x = ".", y = ".", kind = "modified" }
end

describe("git.stage", function()
  local fix

  before_each(function()
    fix = fixture.build()
  end)

  after_each(function()
    fix:destroy()
  end)

  it("stages a modification, a deletion and an untracked file", function()
    local err = await(function(done)
      stage.stage(fix.root, {
        entry("modified.lua", "changes"),
        entry("deleted.lua", "changes"),
        entry("spaced ünicode.txt", "untracked"),
      }, done)
    end)
    assert.is_nil(err)
    local st = porcelain(fix)
    assert.equals("M ", st["modified.lua"])
    assert.equals("D ", st["deleted.lua"])
    assert.equals("A ", st["spaced ünicode.txt"])
    assert.equals("AM", st["staged.lua"], "untouched files stay as they were")
  end)

  it("treats paths literally, not as pathspec globs", function()
    fix:write("[a].lua", "x\n")
    fix:write("a.lua", "y\n")
    assert.is_nil(await(function(done)
      stage.stage(fix.root, { entry("[a].lua", "untracked") }, done)
    end))
    local st = porcelain(fix)
    assert.equals("A ", st["[a].lua"])
    assert.equals("??", st["a.lua"])
  end)

  it("unstages a file back into the working tree", function()
    assert.is_nil(await(function(done)
      stage.unstage(fix.root, { entry("staged.lua", "staged") }, done)
    end))
    assert.equals("??", porcelain(fix)["staged.lua"])
  end)

  it("stages and unstages everything", function()
    assert.is_nil(await(function(done)
      stage.stage_all(fix.root, done)
    end))
    for path, xy in pairs(porcelain(fix)) do
      assert.equals(" ", xy:sub(2, 2), path .. " should have no unstaged part")
    end

    assert.is_nil(await(function(done)
      stage.unstage_all(fix.root, done)
    end))
    for path, xy in pairs(porcelain(fix)) do
      assert.is_truthy(xy:sub(1, 1) == " " or xy == "??", path .. " should have no staged part")
    end
  end)

  it("discards a tracked change and deletes an untracked file", function()
    assert.is_nil(await(function(done)
      stage.discard(fix.root, {
        entry("modified.lua", "changes"),
        entry("deleted.lua", "changes"),
        entry("spaced ünicode.txt", "untracked"),
      }, done)
    end))
    local st = porcelain(fix)
    assert.is_nil(st["modified.lua"])
    assert.is_nil(st["deleted.lua"])
    assert.is_nil(st["spaced ünicode.txt"])
    assert.equals(0, vim.fn.filereadable(fix.root .. "/spaced ünicode.txt"))
    assert.equals(
      "return 2\n",
      table.concat(vim.fn.readfile(fix.root .. "/deleted.lua"), "\n") .. "\n"
    )
  end)

  it("discards only the unstaged half of a partly staged file", function()
    assert.is_nil(await(function(done)
      stage.discard(fix.root, { entry("staged.lua", "changes") }, done)
    end))
    assert.equals("A ", porcelain(fix)["staged.lua"])
  end)

  it("discards everything but keeps what is staged", function()
    assert.is_nil(await(function(done)
      stage.discard_all(fix.root, done)
    end))
    assert.same({ ["staged.lua"] = "A " }, porcelain(fix))
  end)

  it("does nothing for an empty selection", function()
    assert.is_nil(await(function(done)
      stage.stage(fix.root, {}, done)
    end))
    assert.equals(" M", porcelain(fix)["modified.lua"])
  end)
end)
