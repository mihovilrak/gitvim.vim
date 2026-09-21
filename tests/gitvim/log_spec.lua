--- Paged history and per-commit file lists, against the fixture.

local fixture = require("fixture")
local helpers = require("helpers")
local lane = require("gitvim.graph.lane")
local log = require("gitvim.git.log")

describe("git log", function()
  local repo

  before_each(function()
    repo = fixture.build()
  end)

  after_each(function()
    repo:destroy()
  end)

  ---@param opts { skip?: integer, max: integer }
  ---@return gitvim.log.Page
  local function fetch(opts)
    local err, page = helpers.await(function(done)
      log.fetch(repo.root, opts, done)
    end)
    assert.is_nil(err)
    return page
  end

  it("reads the whole history newest first", function()
    local page = fetch({ max = 100 })
    local subjects = {}
    for i, c in ipairs(page.commits) do
      subjects[i] = c.subject
    end
    assert.equals(5, #subjects)
    assert.equals("merge branch 'feature'", subjects[1])
    assert.equals("chore: initial commit", subjects[5])
    assert.is_nil(page.next)

    local merge = page.commits[1]
    assert.equals(repo:sha("HEAD"), merge.sha)
    assert.same({ repo:sha("HEAD^1"), repo:sha("HEAD^2") }, merge.parents)
    assert.equals("gitvim test", merge.author)
    assert.is_true(merge.time > 0)
    assert.same({}, page.commits[5].parents)
  end)

  it("decorates commits with their refs", function()
    repo:git({ "tag", "v1", "HEAD~1" })
    local page = fetch({ max = 100 })
    assert.same({ { kind = "local", name = "main", current = true } }, page.commits[1].refs)

    local by_sha = {}
    for _, c in ipairs(page.commits) do
      by_sha[c.sha] = c
    end
    assert.same({ { kind = "local", name = "feature" } }, by_sha[repo:sha("feature")].refs)
    assert.same({ { kind = "tag", name = "v1" } }, by_sha[repo:sha("v1")].refs)
  end)

  it("parses every ref kind, current branch first", function()
    assert.same(
      {
        { kind = "local", name = "main", current = true },
        { kind = "local", name = "dev" },
        { kind = "remote", name = "origin/main" },
        { kind = "tag", name = "v1.0" },
      },
      log.parse_refs(
        "tag: refs/tags/v1.0, refs/remotes/origin/main, HEAD -> refs/heads/main, refs/heads/dev, refs/remotes/origin/HEAD, refs/stash"
      )
    )
    assert.same({ { kind = "head", name = "HEAD" } }, log.parse_refs("HEAD"))
    assert.same({}, log.parse_refs(""))
  end)

  it("pages with a cursor, and the pages lay out like the whole", function()
    local first = fetch({ max = 2 })
    assert.equals(2, #first.commits)
    assert.equals(2, first.next)
    local second = fetch({ skip = first.next, max = 2 })
    assert.equals(4, second.next)
    local third = fetch({ skip = second.next, max = 2 })
    assert.equals(1, #third.commits)
    assert.is_nil(third.next)

    local paged = vim.list_extend(
      vim.list_extend(vim.list_extend({}, first.commits), second.commits),
      third.commits
    )
    local whole = fetch({ max = 100 }).commits
    assert.same(whole, paged)

    local rows = lane.layout(whole)
    local pictures = {}
    for i, row in ipairs(rows) do
      pictures[i] = lane.text(row.cells)
    end
    assert.same({ "●─╮", "● │", "│ ●", "●─╯", "●" }, pictures)
  end)

  it("keeps subjects byte-exact", function()
    repo:git({ "commit", "--allow-empty", "-m", "tabs\tand | pipes, ünicode" })
    local page = fetch({ max = 1 })
    assert.equals("tabs\tand | pipes, ünicode", page.commits[1].subject)
  end)

  it("treats an unborn HEAD as empty history", function()
    local empty = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(empty, "p")
    vim.system({ "git", "-C", empty, "init", "-q" }):wait()
    local err, page = helpers.await(function(done)
      log.fetch(empty, { max = 10 }, done)
    end)
    vim.fn.delete(empty, "rf")
    assert.is_nil(err)
    assert.same({}, page.commits)
    assert.is_nil(page.next)
  end)

  describe("files", function()
    ---@param rev string
    ---@return gitvim.log.File[]
    local function files(rev)
      local parents = vim.split(
        vim.trim(repo:git({ "log", "-1", "--format=%P", rev })),
        " ",
        { trimempty = true }
      )
      local err, out = helpers.await(function(done)
        log.files(repo.root, { sha = repo:sha(rev), parents = parents }, done)
      end)
      assert.is_nil(err)
      return out
    end

    it("lists a root commit's files against the empty tree", function()
      local out = files("HEAD~3")
      table.sort(out, function(a, b)
        return a.path < b.path
      end)
      assert.same({
        { status = "A", path = "GUIDE.md" },
        { status = "A", path = "README.md" },
        { status = "A", path = "deleted.lua" },
        { status = "A", path = "modified.lua" },
      }, out)
    end)

    it("detects renames", function()
      assert.same({ { status = "R", orig = "GUIDE.md", path = "docs/guide.md" } }, files("HEAD~2"))
    end)

    it("diffs a merge against its first parent", function()
      assert.same({ { status = "A", path = "widget.lua" } }, files("HEAD"))
    end)

    it("uses the empty tree as a root commit's base", function()
      assert.equals(log.EMPTY_TREE, log.base({ parents = {} }))
      assert.equals("p1", log.base({ parents = { "p1", "p2" } }))
    end)
  end)
end)
