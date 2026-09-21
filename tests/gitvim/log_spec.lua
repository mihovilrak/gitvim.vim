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

  describe("history", function()
    --- Read one page off `reader`.
    ---@param reader gitvim.log.HistoryReader
    ---@param max integer
    ---@return gitvim.log.History
    local function read(reader, max)
      local err, page = helpers.await(function(done)
        reader:read(max, done)
      end)
      assert.is_nil(err)
      return page
    end

    ---@param path string
    ---@param max integer
    ---@param opts? { follow?: boolean }
    ---@return gitvim.log.History
    local function history(path, max, opts)
      local reader = log.history(repo.root, path, opts)
      local page = read(reader, max)
      reader:close()
      return page
    end

    it("follows a file across its rename, matching git log --follow", function()
      local page = history("docs/guide.md", 100)
      local expected = vim.split(
        vim.trim(repo:git({ "log", "--follow", "--format=%H", "--", "docs/guide.md" })),
        "\n"
      )
      local shas = {}
      for i, c in ipairs(page.commits) do
        shas[i] = c.sha
      end
      assert.same(expected, shas)
      assert.is_nil(page.next)

      local rename, initial = page.commits[1], page.commits[2]
      assert.equals("rename: docs/guide.md <- GUIDE.md", rename.subject)
      assert.same({ status = "R", orig = "GUIDE.md", path = "docs/guide.md" }, rename.file)
      assert.same({ repo:sha("HEAD~3") }, rename.parents)
      assert.equals("gitvim test", rename.author)
      assert.equals("chore: initial commit", initial.subject)
      assert.same({ status = "A", path = "GUIDE.md" }, initial.file)
    end)

    it("stops at the rename without follow", function()
      local page = history("docs/guide.md", 100, { follow = false })
      assert.equals(1, #page.commits)
      assert.equals("A", page.commits[1].file.status)
    end)

    it("pages off one git log, and knows when the last page is in", function()
      local reader = log.history(repo.root, "docs/guide.md")
      local first = read(reader, 1)
      assert.equals(1, #first.commits)
      assert.equals(1, first.next)
      local second = read(reader, 1)
      assert.equals("chore: initial commit", second.commits[1].subject)
      assert.is_nil(second.next)
      reader:close()
    end)

    it("reads on after the idle git log was ended", function()
      local idle_ms = log.idle_ms
      log.idle_ms = 20
      local reader = log.history(repo.root, "docs/guide.md")
      local ok, err = pcall(function()
        local first = read(reader, 1)
        assert.equals("rename: docs/guide.md <- GUIDE.md", first.commits[1].subject)
        assert.is_true(vim.wait(2000, function()
          return reader.proc == nil
        end, 10))
        local second = read(reader, 1)
        assert.equals(1, #second.commits)
        assert.equals("chore: initial commit", second.commits[1].subject)
        assert.is_nil(second.next)
      end)
      reader:close()
      log.idle_ms = idle_ms
      assert.is_true(ok, err)
    end)

    it("parses output cut at any byte like the whole", function()
      local cmd =
        vim.list_extend({ "git", "-C", repo.root }, log.history_args("docs/guide.md", true))
      local out = vim.system(cmd, { text = false }):wait().stdout
      local whole = log.parse_history(out)
      assert.equals(2, #whole)
      for _, size in ipairs({ 1, 3, 7, 64 }) do
        local commits, buf = {}, ""
        for i = 1, #out, size do
          local got
          got, buf = log.parse_history_prefix(buf .. out:sub(i, i + size - 1))
          vim.list_extend(commits, got)
        end
        vim.list_extend(commits, log.parse_history(buf))
        assert.same(whole, commits)
      end
    end)

    it("reads a file changed across a merge", function()
      local page = history("README.md", 100)
      local subjects = {}
      for i, c in ipairs(page.commits) do
        subjects[i] = c.subject
        assert.equals("README.md", c.file.path)
      end
      assert.same({ "fix: tweak README", "chore: initial commit" }, subjects)
    end)

    it("is empty for a file never committed", function()
      assert.same({}, history("staged.lua", 10).commits)
      assert.same({}, history("spaced ünicode.txt", 10).commits)
    end)

    it("parses a commit that left the file's name-status out", function()
      local out = table.concat({
        "",
        "a1",
        "p1 p2",
        "",
        "me",
        "10",
        "merge",
        "",
        "b2",
        "p3",
        "",
        "me",
        "5",
        "edit",
        "\nM",
        "f.txt",
        "",
      }, "\0")
      local commits = log.parse_history(out)
      assert.equals(2, #commits)
      assert.is_nil(commits[1].file)
      assert.same({ "p1", "p2" }, commits[1].parents)
      assert.same({ status = "M", path = "f.txt" }, commits[2].file)
    end)
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
