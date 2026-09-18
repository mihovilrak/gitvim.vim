--- git/status.lua: the porcelain v2 parser.
---
--- Split in two: `parse()` is pure, so the exotic record shapes are asserted
--- against literal git output, while the common cases go through a real repo
--- so the literals above can never drift from what git actually emits.

local fixture = require("fixture")
local helpers = require("helpers")
local status = require("gitvim.git.status")

local await, entry = helpers.await, helpers.entry

--- Join records the way `-z` does: NUL after every field git terminates.
---@param records string[]
---@return string
local function z(records)
  return table.concat(records, "\0") .. "\0"
end

describe("status.parse", function()
  it("reads the branch header", function()
    local result = status.parse(z({
      "# branch.oid 1c5a0f8c6a3a0ba1a5d0b0d5a7c4f0e1d2c3b4a5",
      "# branch.head main",
      "# branch.upstream origin/main",
      "# branch.ab +2 -3",
    }))

    assert.equals("1c5a0f8c6a3a0ba1a5d0b0d5a7c4f0e1d2c3b4a5", result.branch.oid)
    assert.equals("main", result.branch.head)
    assert.equals("origin/main", result.branch.upstream)
    assert.equals(2, result.branch.ahead)
    assert.equals(3, result.branch.behind)
    assert.is_false(result.branch.detached)
    assert.same({}, result.entries)
  end)

  it("treats (initial) and (detached) as absent rather than as names", function()
    local unborn = status.parse(z({ "# branch.oid (initial)", "# branch.head main" }))
    assert.is_nil(unborn.branch.oid)
    assert.equals("main", unborn.branch.head)

    local detached = status.parse(z({ "# branch.oid abc1234", "# branch.head (detached)" }))
    assert.is_nil(detached.branch.head)
    assert.is_true(detached.branch.detached)
  end)

  it("defaults ahead/behind to zero without an upstream", function()
    local result = status.parse(z({ "# branch.head main" }))
    assert.is_nil(result.branch.upstream)
    assert.equals(0, result.branch.ahead)
    assert.equals(0, result.branch.behind)
  end)

  it("parses unmerged records into the merge group", function()
    local result = status.parse(z({
      "u UU N 100644 100644 100644 100644 aaa bbb ccc conflicted.lua",
    }))

    local e = result.entries[1]
    assert.equals("conflicted.lua", e.path)
    assert.equals("merge", e.group)
    assert.equals("U", e.x)
    assert.equals("U", e.y)
    assert.equals("conflict", e.kind)
    -- The raw XY pair is kept: "UU", "AA", "DU" and friends each need a
    -- different resolution offer once the conflict UI lands.
    assert.equals("UU", e.conflict)
  end)

  it("parses the submodule field", function()
    local result = status.parse(z({
      "1 .M SCMU 160000 160000 160000 aaa aaa vendor/lib",
      "1 .M N... 100644 100644 100644 aaa aaa plain.lua",
    }))

    local sub = entry(result, "vendor/lib")
    assert.is_table(sub.submodule)
    assert.is_true(sub.submodule.commit)
    assert.is_true(sub.submodule.modified)
    assert.is_true(sub.submodule.untracked)

    assert.is_nil(entry(result, "plain.lua").submodule)
  end)

  it("distinguishes a submodule with only a new commit", function()
    local result = status.parse(z({
      "1 .M SC.. 160000 160000 160000 aaa aaa vendor/lib",
    }))
    local sub = entry(result, "vendor/lib")
    assert.is_true(sub.submodule.commit)
    assert.is_false(sub.submodule.modified)
    assert.is_false(sub.submodule.untracked)
  end)

  it("keeps ignored entries out of the untracked group", function()
    local result = status.parse(z({ "? untracked.lua", "! node_modules/" }))
    assert.equals("untracked", entry(result, "untracked.lua").group)
    assert.equals("ignored", entry(result, "node_modules/").group)
  end)

  it("reads a copy record's source from the following NUL field", function()
    local result = status.parse(z({
      "2 C. N... 100644 100644 100644 aaa bbb C87 copy.lua",
      "origin.lua",
    }))

    local e = result.entries[1]
    assert.equals("copy.lua", e.path)
    assert.equals("origin.lua", e.orig_path)
    assert.equals("copied", e.kind)
    assert.equals(87, e.score)
  end)

  it("ignores stray empty records", function()
    assert.same({}, status.parse("").entries)
    assert.same({}, status.parse("\0\0").entries)
  end)
end)

describe("status against a real repository", function()
  ---@type gitvim.Fixture
  local repo
  ---@type gitvim.status.Result
  local result

  before_each(function()
    repo = fixture.build()
    local err
    err, result = await(function(done)
      status.get(repo.root, nil, done)
    end)
    assert.is_nil(err)
  end)

  after_each(function()
    repo:destroy()
  end)

  it("reports the branch with no upstream", function()
    assert.equals("main", result.branch.head)
    assert.is_nil(result.branch.upstream)
    assert.is_string(result.branch.oid)
    assert.equals(40, #result.branch.oid)
  end)

  it("lists a staged-then-modified file in both staged and changes", function()
    local staged = entry(result, "staged.lua", "staged")
    local changed = entry(result, "staged.lua", "changes")

    assert.is_table(staged)
    assert.is_table(changed)
    assert.equals("added", staged.kind)
    assert.equals("modified", changed.kind)
    -- Both halves keep the raw XY, so a row can render "AM" verbatim.
    assert.equals("A", staged.x)
    assert.equals("M", staged.y)
  end)

  it("puts an unstaged modification in changes only", function()
    assert.equals("modified", entry(result, "modified.lua", "changes").kind)
    assert.is_nil(entry(result, "modified.lua", "staged"))
  end)

  it("reports an unstaged deletion", function()
    local e = entry(result, "deleted.lua", "changes")
    assert.equals("deleted", e.kind)
    assert.equals("D", e.y)
  end)

  it("returns a path with a space and a non-ASCII byte unmangled", function()
    -- The whole reason for -z: without it this arrives as
    -- "spaced \303\274nicode.txt" wrapped in double quotes.
    local e = entry(result, "spaced ünicode.txt", "untracked")
    assert.is_table(e)
    assert.equals("?", e.x)
    assert.is_nil(e.orig_path)
  end)

  it("omits ignored files unless asked", function()
    repo:write(".gitignore", "*.log\n")
    repo:write("debug.log", "noise\n")

    local _, plain = await(function(done)
      status.get(repo.root, nil, done)
    end)
    assert.is_nil(entry(plain, "debug.log"))

    local _, ignored = await(function(done)
      status.get(repo.root, { ignored = true }, done)
    end)
    assert.equals("ignored", entry(ignored, "debug.log").group)
  end)

  it("parses a staged rename with its similarity score", function()
    repo:git({ "mv", "docs/guide.md", "docs/manual.md" })

    local _, renamed = await(function(done)
      status.get(repo.root, nil, done)
    end)

    local e = entry(renamed, "docs/manual.md", "staged")
    assert.is_table(e)
    assert.equals("renamed", e.kind)
    assert.equals("docs/guide.md", e.orig_path)
    assert.equals(100, e.score)
  end)

  it("reports conflicted files in the merge group", function()
    repo:destroy()
    repo = fixture.build_conflict()

    local _, conflicted = await(function(done)
      status.get(repo.root, nil, done)
    end)

    local e = entry(conflicted, "conflicted.lua")
    assert.equals("merge", e.group)
    assert.equals("conflict", e.kind)
    assert.equals("AA", e.conflict) -- added on both sides
  end)

  it("buckets entries by group", function()
    local groups = status.by_group(result)
    assert.equals(1, #groups.staged)
    assert.equals(3, #groups.changes) -- staged.lua, modified.lua, deleted.lua
    assert.equals(1, #groups.untracked)
    assert.equals(0, #groups.merge)
  end)
end)
