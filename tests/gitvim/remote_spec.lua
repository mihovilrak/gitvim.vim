--- Fetch, pull and push against a local bare remote, confirmed with git.

local fixture = require("fixture")
local helpers = require("helpers")
local remote = require("gitvim.git.remote")
local repo_mod = require("gitvim.git.repo")

local await = helpers.await

describe("git.remote", function()
  local fix, bare, notify, messages

  ---@return gitvim.Repo
  local function detect()
    repo_mod.reset()
    local err, repo = await(function(done)
      repo_mod.detect(fix.root, done)
    end)
    assert.is_nil(err)
    -- Detection finds the repository; HEAD and upstream come from a status read.
    assert.is_nil(await(function(done)
      repo:read_head(done)
    end))
    return repo
  end

  ---@param args string[]
  ---@param cwd string
  ---@return string
  local function git(args, cwd)
    local res = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
    assert(res.code == 0, res.stderr)
    return res.stdout
  end

  before_each(function()
    fix = fixture.build()
    bare = vim.fn.tempname()
    vim.fn.mkdir(bare, "p")
    git({ "init", "-q", "--bare", "-b", "main" }, bare)
    messages = {}
    notify = vim.notify
    vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
      messages[#messages + 1] = msg
    end
  end)

  after_each(function()
    vim.notify = notify
    fix:destroy()
    vim.fn.delete(bare, "rf")
  end)

  it("publishes a branch without an upstream", function()
    fix:git({ "remote", "add", "origin", bare })
    local repo = detect()
    assert.is_nil(repo.upstream)

    assert.is_nil(await(function(done)
      remote.push(repo, done)
    end))
    assert.equals("origin/main", vim.trim(fix:git({ "rev-parse", "--abbrev-ref", "main@{u}" })))
    assert.equals(fix:sha("HEAD"), vim.trim(git({ "rev-parse", "main" }, bare)))
    assert.same({ "gitvim: Publishing main to origin...", "gitvim: Published main" }, messages)
  end)

  it("pushes to an existing upstream, then fetches and pulls", function()
    fix:git({ "remote", "add", "origin", bare })
    fix:git({ "push", "-q", "-u", "origin", "main" })
    fix:git({ "add", "-A" })
    fix:git({ "commit", "-q", "-m", "local" })
    local repo = detect()
    assert.equals("origin/main", repo.upstream)

    assert.is_nil(await(function(done)
      remote.push(repo, done)
    end))
    assert.equals(fix:sha("HEAD"), vim.trim(git({ "rev-parse", "main" }, bare)))

    -- Someone else pushes; fetch sees it, pull brings it in.
    local other = vim.fn.tempname()
    git({ "clone", "-q", bare, other }, vim.fn.getcwd())
    git({ "commit", "-q", "--allow-empty", "-m", "theirs" }, other)
    git({ "push", "-q" }, other)
    local theirs = vim.trim(git({ "rev-parse", "HEAD" }, other))
    vim.fn.delete(other, "rf")

    assert.is_nil(await(function(done)
      remote.fetch(fix.root, done)
    end))
    assert.equals(theirs, fix:sha("origin/main"))
    assert.are_not.equal(theirs, fix:sha("HEAD"))

    assert.is_nil(await(function(done)
      remote.pull(fix.root, done)
    end))
    assert.equals(theirs, fix:sha("HEAD"))
    assert.equals("gitvim: Pulled", messages[#messages])
  end)

  it("explains a push with no remote configured", function()
    local err = await(function(done)
      remote.push(detect(), done)
    end)
    assert.equals("no_remote", err.kind)
    assert.equals(0, #vim.tbl_filter(function(m)
      return m:match("%.%.%.$")
    end, messages), "nothing was started")
  end)

  it("refuses to push a detached HEAD", function()
    fix:git({ "remote", "add", "origin", bare })
    fix:git({ "checkout", "-q", "--detach" })
    local err = await(function(done)
      remote.push(detect(), done)
    end)
    assert.equals("detached", err.kind)
  end)

  it("reports a failed fetch", function()
    fix:git({ "remote", "add", "origin", bare .. "-missing" })
    local err = await(function(done)
      remote.fetch(fix.root, done)
    end)
    assert.is_table(err)
    assert.is_truthy(messages[#messages]:match("^gitvim: git fetch"))
  end)
end)
