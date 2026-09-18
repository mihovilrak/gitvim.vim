--- git/cli.lua: the single place gitvim spawns git.

local fixture = require("fixture")
local helpers = require("helpers")
local cli = require("gitvim.git.cli")

local await = helpers.await

describe("cli.classify", function()
  -- Classification is asserted against literal stderr rather than by
  -- provoking each failure: several of them (permission, auth, network) are
  -- not reproducible in a sandbox or when the suite runs as root.
  local cases = {
    not_a_repo = "fatal: not a git repository (or any of the parent directories): .git",
    bad_revision = "fatal: bad revision 'nope'",
    bad_path = "fatal: pathspec 'nope.lua' did not match any files",
    permission = 'error: open("secret.lua"): Permission denied',
    auth = "git@github.com: Permission denied (publickey).",
    network = "fatal: unable to access 'https://example.invalid/': Could not resolve host",
    locked = "fatal: Unable to create '/repo/.git/index.lock': File exists.",
    conflict = "error: Your local changes to the following files would be overwritten by merge:",
  }

  for kind, stderr in pairs(cases) do
    it("maps " .. kind, function()
      assert.equals(kind, cli.classify(1, stderr, 0))
    end)
  end

  it("prefers auth over the generic permission match", function()
    -- "Permission denied (publickey)" contains "permission denied"; ordering
    -- inside the pattern table is what keeps this from becoming a filesystem
    -- error report on a failed push.
    assert.equals("auth", cli.classify(128, "git@host: Permission denied (publickey).", 0))
  end)

  it("reports a signalled process as killed regardless of stderr", function()
    assert.equals("killed", cli.classify(124, "fatal: bad revision 'x'", 9))
  end)

  it("falls back to unknown", function()
    assert.equals("unknown", cli.classify(1, "fatal: something new in git 3.0", 0))
  end)
end)

describe("cli.run", function()
  ---@type gitvim.Fixture
  local repo

  before_each(function()
    repo = fixture.build()
  end)

  after_each(function()
    repo:destroy()
  end)

  it("returns captured stdout on success", function()
    local err, res = await(function(done)
      cli.run({ "rev-parse", "--abbrev-ref", "HEAD" }, { cwd = repo.root }, done)
    end)

    assert.is_nil(err)
    assert.equals(0, res.code)
    assert.equals("main", vim.trim(res.stdout))
  end)

  it("classifies a directory outside any repository", function()
    local outside = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(outside, "p")

    local err = await(function(done)
      -- GIT_CEILING_DIRECTORIES stops the parent walk at the tempdir, so the
      -- result does not depend on whether /tmp happens to sit inside a repo.
      cli.run(
        { "rev-parse", "--show-toplevel" },
        { cwd = outside, env = { GIT_CEILING_DIRECTORIES = outside } },
        done
      )
    end)
    vim.fn.delete(outside, "rf")

    assert.is_table(err)
    assert.equals("not_a_repo", err.kind)
    assert.equals(128, err.code)
    assert.is_truthy(err.message:match("^not a git repository"))
  end)

  it("classifies a bad revision", function()
    local err = await(function(done)
      cli.run({ "rev-parse", "--verify", "no/such/ref" }, { cwd = repo.root }, done)
    end)

    assert.is_table(err)
    assert.equals("bad_revision", err.kind)
    assert.same({ "rev-parse", "--verify", "no/such/ref" }, err.args)
    assert.equals(repo.root, err.cwd)
  end)

  it("classifies a pathspec that matches nothing", function()
    local err = await(function(done)
      cli.run({ "add", "no-such-file.lua" }, { cwd = repo.root }, done)
    end)

    assert.is_table(err)
    assert.equals("bad_path", err.kind)
  end)

  it("reports a missing executable as a spawn error", function()
    local err = await(function(done)
      cli.run({ "status" }, { cwd = repo.root .. "/does-not-exist" }, done)
    end)

    assert.is_table(err)
    assert.equals("spawn", err.kind)
  end)

  it("strips the fatal: prefix from the message", function()
    local err = await(function(done)
      cli.run({ "rev-parse", "--verify", "no/such/ref" }, { cwd = repo.root }, done)
    end)
    assert.is_nil(err.message:match("^fatal:"))
  end)

  it("feeds stdin through", function()
    local err, res = await(function(done)
      cli.run({ "hash-object", "-w", "--stdin" }, { cwd = repo.root, stdin = "hello\n" }, done)
    end)

    assert.is_nil(err)
    local oid = vim.trim(res.stdout)
    assert.equals("hello\n", repo:git({ "cat-file", "-p", oid }))
  end)

  it("invokes the callback on the main loop", function()
    local in_fast_event = await(function(done)
      cli.run({ "rev-parse", "HEAD" }, { cwd = repo.root }, function()
        done(vim.in_fast_event())
      end)
    end)
    assert.is_false(in_fast_event)
  end)

  it("keeps quoted paths unquoted via core.quotepath=false", function()
    local err, res = await(function(done)
      cli.run({ "status", "--porcelain=v1" }, { cwd = repo.root }, done)
    end)

    assert.is_nil(err)
    assert.is_truthy(res.stdout:find("spaced ünicode.txt", 1, true))
  end)

  it("formats an error for display", function()
    local err = await(function(done)
      cli.run({ "rev-parse", "--verify", "no/such/ref" }, { cwd = repo.root }, done)
    end)
    assert.is_truthy(
      cli.format_error(err):match("^gitvim: git rev%-parse %-%-verify no/such/ref: ")
    )
  end)
end)

describe("cli.sync", function()
  it("splits NUL-separated output", function()
    assert.same({ "a", "b" }, cli.split_nul("a\0b\0"))
    assert.same({ "a", "b" }, cli.split_nul("a\0b"))
    assert.same({}, cli.split_nul(""))
  end)

  it("runs blocking when no UI is attached", function()
    -- The headless test runner has no UI, which is exactly the condition the
    -- guard allows; with a UI it must raise instead.
    assert.equals(0, #vim.api.nvim_list_uis())
    local err, res = cli.sync({ "--version" })
    assert.is_nil(err)
    assert.is_truthy(res.stdout:match("^git version"))
  end)
end)
