--- state.lua: the per-repo store and the event bus.

local fixture = require("fixture")
local helpers = require("helpers")
local repo_mod = require("gitvim.git.repo")
local state = require("gitvim.state")

local await = helpers.await

describe("state store", function()
  before_each(function()
    state.reset()
    repo_mod.reset()
  end)

  it("creates a store on first use and reuses it after", function()
    local a = state.get("/tmp/example")
    a.draft = "wip: message"
    assert.is_true(rawequal(a, state.get("/tmp/example")))
    assert.equals("wip: message", state.get("/tmp/example").draft)
  end)

  it("keys stores by normalized root", function()
    state.get("/tmp/example")
    assert.is_true(rawequal(state.get("/tmp/example"), state.get("/tmp/example/")))
    assert.equals(1, vim.tbl_count(state.all()))
  end)

  it("starts dirty, because nothing has been fetched yet", function()
    local store = state.get("/tmp/example")
    assert.is_true(store:is_dirty("status"))
    assert.is_true(store:is_dirty("head"))
    assert.is_false(store:is_dirty("graph"))
  end)

  it("returns empty groups before the first refresh", function()
    local groups = state.get("/tmp/example"):groups()
    assert.same({}, groups.staged)
    assert.same({}, groups.untracked)
  end)

  it("toggles group collapse", function()
    local store = state.get("/tmp/example")
    assert.is_false(store:is_collapsed("staged"))
    store:toggle_collapsed("staged")
    assert.is_true(store:is_collapsed("staged"))
    store:toggle_collapsed("staged")
    assert.is_false(store:is_collapsed("staged"))
  end)
end)

describe("state event bus", function()
  before_each(function()
    state.reset()
    repo_mod.reset()
  end)

  it("delivers events to subscribers", function()
    local seen = {}
    state.subscribe("dirty", function(payload)
      table.insert(seen, payload.slot)
    end)

    state.get("/tmp/example"):mark_dirty("graph")
    assert.same({ "graph" }, seen)
  end)

  it("stops delivering after unsubscribe", function()
    local count = 0
    local off = state.subscribe("dirty", function()
      count = count + 1
    end)

    local store = state.get("/tmp/example")
    store:mark_dirty("graph")
    off()
    store:mark_dirty("graph")

    assert.equals(1, count)
  end)

  it("isolates a throwing subscriber from the rest of the fan-out", function()
    local notified = {}
    local notify = vim.notify
    vim.notify = function(msg)
      table.insert(notified, msg)
    end

    local reached = false
    state.subscribe("dirty", function()
      error("boom")
    end)
    state.subscribe("dirty", function()
      reached = true
    end)

    local ok, err = pcall(function()
      state.get("/tmp/example"):mark_dirty("graph")
    end)
    vim.notify = notify

    assert.is_true(ok, tostring(err))
    assert.is_true(reached)
    assert.equals(1, #notified)
    assert.is_truthy(notified[1]:match("listener failed"))
  end)

  it("marks every store dirty at once", function()
    local a, b = state.get("/tmp/a"), state.get("/tmp/b")
    a:clear_dirty("status")
    b:clear_dirty("status")

    state.mark_all_dirty("status")
    assert.is_true(a:is_dirty("status"))
    assert.is_true(b:is_dirty("status"))
  end)
end)

describe("state fed by a real refresh", function()
  ---@type gitvim.Fixture
  local fix

  before_each(function()
    state.reset()
    repo_mod.reset()
    fix = fixture.build()
  end)

  after_each(function()
    fix:destroy()
    state.reset()
    repo_mod.reset()
  end)

  it("stores status, clears the dirty flags and emits head then status", function()
    local events = {}
    state.subscribe("head", function(p)
      table.insert(events, { "head", p.branch.head })
    end)
    state.subscribe("status", function(p)
      table.insert(events, { "status", #p.result.entries })
    end)

    local err, store = await(function(done)
      require("gitvim").refresh(fix.root, done)
    end)

    assert.is_nil(err)
    assert.equals(fix.root, store.root)
    assert.is_false(store:is_dirty("status"))
    assert.is_false(store:is_dirty("head"))

    -- head first: the sidebar header must never render a stale branch beside
    -- a fresh file list.
    assert.equals("head", events[1][1])
    assert.equals("main", events[1][2])
    assert.equals("status", events[2][1])
    assert.is_true(events[2][2] > 0)
  end)

  it("pushes the branch header onto the Repo", function()
    await(function(done)
      require("gitvim").refresh(fix.root, done)
    end)

    local repo = repo_mod.get(fix.root)
    assert.equals("main", repo.head)
    assert.equals(fix:sha("HEAD"), repo.oid)
  end)

  it("buckets the fixture's dirty tree", function()
    local _, store = await(function(done)
      require("gitvim").refresh(fix.root, done)
    end)

    local groups = store:groups()
    assert.equals(1, #groups.staged)
    assert.equals(3, #groups.changes)
    assert.equals(1, #groups.untracked)
  end)

  it("reports a detection failure without creating a store", function()
    local outside = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(outside, "p")

    local err, store = await(function(done)
      require("gitvim").refresh(outside, done)
    end)
    vim.fn.delete(outside, "rf")

    assert.equals("not_a_repo", err.kind)
    assert.is_nil(store)
    assert.equals(0, vim.tbl_count(state.all()))
  end)
end)
