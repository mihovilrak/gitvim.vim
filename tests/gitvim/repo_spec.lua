--- git/repo.lua: detection and the repo registry (D4).

local fixture = require("fixture")
local helpers = require("helpers")
local repo_mod = require("gitvim.git.repo")

local await = helpers.await

describe("repo.detect", function()
  ---@type gitvim.Fixture
  local fix

  before_each(function()
    repo_mod.reset()
    fix = fixture.build()
  end)

  after_each(function()
    fix:destroy()
    repo_mod.reset()
  end)

  it("finds the worktree root from a nested file", function()
    local err, repo = await(function(done)
      repo_mod.detect(fix.root .. "/docs/guide.md", done)
    end)

    assert.is_nil(err)
    assert.equals(fix.root, repo.root)
    assert.equals(vim.fs.basename(fix.root), repo.name)
    assert.equals(fix.root .. "/.git", repo.gitdir)
  end)

  it("returns the same Repo object for two paths in one repository", function()
    local _, a = await(function(done)
      repo_mod.detect(fix.root, done)
    end)
    local _, b = await(function(done)
      repo_mod.detect(fix.root .. "/docs/guide.md", done)
    end)

    assert.is_true(rawequal(a, b))
    assert.equals(1, vim.tbl_count(repo_mod.all()))
  end)

  it("reports not_a_repo outside a repository", function()
    local outside = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(outside, "p")

    local err, repo = await(function(done)
      repo_mod.detect(outside, done)
    end)
    vim.fn.delete(outside, "rf")

    assert.is_nil(repo)
    assert.equals("not_a_repo", err.kind)
  end)

  it("keeps the callback asynchronous on a cache hit", function()
    await(function(done)
      repo_mod.detect(fix.root, done)
    end)

    -- Second call answers from cache; it must still not run inline, or a
    -- caller's state would be half-built when the callback fires.
    local inline = true
    local fired = false
    repo_mod.detect(fix.root, function()
      fired = true
      assert.is_false(inline)
    end)
    inline = false
    assert.is_true(vim.wait(1000, function()
      return fired
    end, 10))
  end)

  it("forgets a cached lookup on request", function()
    await(function(done)
      repo_mod.detect(fix.root, done)
    end)
    repo_mod.forget(fix.root)

    local err, repo = await(function(done)
      repo_mod.detect(fix.root, done)
    end)
    assert.is_nil(err)
    assert.equals(fix.root, repo.root)
  end)
end)

describe("Repo", function()
  ---@type gitvim.Fixture
  local fix
  ---@type gitvim.Repo
  local repo

  before_each(function()
    repo_mod.reset()
    fix = fixture.build()
    local err
    err, repo = await(function(done)
      repo_mod.detect(fix.root, done)
    end)
    assert.is_nil(err)
  end)

  after_each(function()
    fix:destroy()
    repo_mod.reset()
  end)

  it("reads HEAD without listing files", function()
    local err = await(function(done)
      repo:read_head(done)
    end)

    assert.is_nil(err)
    assert.equals("main", repo.head)
    assert.is_false(repo.detached)
    assert.equals(fix:sha("HEAD"), repo.oid)
    assert.equals("main", repo:head_label())
  end)

  it("labels a detached HEAD with an abbreviated sha", function()
    fix:git({ "checkout", "--detach", "HEAD" })

    local err = await(function(done)
      repo:read_head(done)
    end)

    assert.is_nil(err)
    assert.is_nil(repo.head)
    assert.is_true(repo.detached)
    assert.equals(fix:sha("HEAD"):sub(1, 7), repo:head_label())
  end)

  it("tracks the active repository", function()
    assert.is_nil(repo_mod.active())
    repo_mod.set_active(fix.root)
    assert.equals(repo, repo_mod.active())
  end)
end)
