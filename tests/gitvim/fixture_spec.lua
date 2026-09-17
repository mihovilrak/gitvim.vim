--- Validates the test harness itself: the fixture must produce the exact topology
--- and dirty-state that every other spec asserts against.

local fixture = require("fixture")

describe("fixture", function()
  ---@type gitvim.Fixture
  local repo

  before_each(function()
    repo = fixture.build()
  end)

  after_each(function()
    repo:destroy()
  end)

  it("builds a repo on branch main", function()
    assert.equals("main", vim.trim(repo:git({ "rev-parse", "--abbrev-ref", "HEAD" })))
  end)

  it("has a merge commit at HEAD with two parents", function()
    local parents =
      vim.split(vim.trim(repo:git({ "rev-list", "--parents", "-n", "1", "HEAD" })), " ")
    assert.equals(3, #parents, "expected <commit> <parent1> <parent2>")
  end)

  it("records every dirty-state group in porcelain v2", function()
    -- `-z` is not optional: without it git quote-escapes any path with a space
    -- or a non-ASCII byte, so "spaced \195\188nicode.txt" comes back mangled.
    -- This is the exact command git/status.lua will run.
    local out = repo:git({
      "status",
      "--porcelain=v2",
      "--branch",
      "--untracked-files=all",
      "-z",
      "--ignore-submodules=none",
    })

    local records = {}
    for _, rec in ipairs(vim.split(out, "\0", { plain = true })) do
      if rec ~= "" then
        table.insert(records, rec)
      end
    end

    local function find(pat)
      for _, rec in ipairs(records) do
        if rec:match(pat) then
          return rec
        end
      end
    end

    -- staged.lua: added to the index, then modified again in the worktree.
    assert.is_truthy(find("^1 AM .* staged%.lua$"), "staged.lua should be AM")
    -- modified.lua: tracked, modified, not staged.
    assert.is_truthy(find("^1 %.M .* modified%.lua$"), "modified.lua should be .M")
    -- deleted.lua: tracked, removed from the worktree.
    assert.is_truthy(find("^1 %.D .* deleted%.lua$"), "deleted.lua should be .D")
    -- untracked, with a space and a non-ASCII character in the name, unquoted.
    assert.are.same("? spaced \195\188nicode.txt", find("^%? "))
  end)

  it("reports ahead/behind in the branch header", function()
    local out = repo:git({ "status", "--porcelain=v2", "--branch" })
    assert.is_truthy(out:match("# branch%.head main"))
  end)

  it("preserves history across the rename for --follow", function()
    local log = repo:git({ "log", "--follow", "--pretty=format:%s", "--", "docs/guide.md" })
    local subjects = vim.split(vim.trim(log), "\n")
    assert.equals(2, #subjects, "rename commit + the commit that created GUIDE.md")
    assert.is_truthy(subjects[2]:match("initial commit"))
  end)

  it("builds a conflicted repo on demand", function()
    local conflicted = fixture.build_conflict()
    local out = conflicted:git({ "status", "--porcelain=v2", "--branch" })
    assert.is_truthy(out:match("^u ") or out:match("\nu "), "expected an unmerged entry")
    conflicted:destroy()
  end)
end)
