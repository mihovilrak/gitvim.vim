--- Performance gates (Plan.md §6), measured headlessly:
---
---   sidebar open, first paint with status      < 200 ms
---   GRAPH first page rendered                  < 150 ms
---   longest main-loop block during a refresh   < 16 ms
---
--- on a generated repository with 10k+ commits and 1k+ changed files.
---
---   make bench
---   nvim --headless --noplugin -u tests/minimal_init.lua -c "luafile scripts/bench.lua"
---
--- The repository is built once into $TMPDIR/gitvim-bench-repo, or $BENCH_REPO
--- (delete it to rebuild). BENCH_RUNS sets the timed runs per gate (default 7).

-- Outside the project by default: a worktree on a slow or network-backed
-- mount measures the filesystem rather than gitvim.
local repo = vim.env.BENCH_REPO or vim.fs.joinpath(vim.uv.os_tmpdir(), "gitvim-bench-repo")

local COMMITS = 10000
local DIRS, PER_DIR = 20, 100 -- 2000 tracked files
local MODIFIED, DELETED, UNTRACKED = 1000, 50, 200
local RUNS = tonumber(vim.env.BENCH_RUNS) or 7

local GATES = { open = 200, graph = 150, block = 16 }

local function out(fmt, ...)
  io.stdout:write(fmt:format(...) .. "\n")
end

local function now()
  return vim.uv.hrtime() / 1e6
end

---@param cmd string[]
---@param opts? table
local function run(cmd, opts)
  local res =
    vim.system(cmd, vim.tbl_extend("force", { cwd = repo, text = true }, opts or {})):wait()
  if res.code ~= 0 then
    error(table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
  end
  return res.stdout
end

local function file(d, f)
  return ("src/d%02d/f%03d.txt"):format(d, f)
end

-- ---------------------------------------------------------------------------
-- fixture
-- ---------------------------------------------------------------------------

--- One `git fast-import` stream: an initial commit with every file, then a
--- linear history touching one file per commit, with a short side branch
--- merged back every 100 commits so the graph has lanes to draw.
local function build()
  vim.fn.delete(repo, "rf")
  vim.fn.mkdir(repo, "p")
  run({ "git", "init", "-q", "-b", "main" })

  local s = {}
  local mark, t = 0, 1600000000
  local function data(text)
    s[#s + 1] = ("data %d\n%s\n"):format(#text, text)
  end
  local function commit(branch, msg, parents, changes)
    mark = mark + 1
    t = t + 60
    s[#s + 1] = ("commit refs/heads/%s\nmark :%d\n"):format(branch, mark)
    s[#s + 1] = ("author Bench <bench@example.com> %d +0000\n"):format(t)
    s[#s + 1] = ("committer Bench <bench@example.com> %d +0000\n"):format(t)
    data(msg)
    for i, p in ipairs(parents) do
      s[#s + 1] = (i == 1 and "from :%d\n" or "merge :%d\n"):format(p)
    end
    for _, c in ipairs(changes) do
      s[#s + 1] = ("M 100644 inline %s\n"):format(c[1])
      data(c[2])
    end
    return mark
  end

  local all = {}
  for d = 0, DIRS - 1 do
    for f = 0, PER_DIR - 1 do
      all[#all + 1] = { file(d, f), ("file %d/%d\nline 2\nline 3\n"):format(d, f) }
    end
  end
  local head = commit("main", "initial", {}, all)
  local n = 1
  while n < COMMITS do
    local i = n
    local change = { { file(i % DIRS, i % PER_DIR), ("rev %d\nline 2\nline 3\n"):format(i) } }
    if i % 100 == 0 then
      local side = head
      for k = 1, 3 do
        side = commit("side", ("side %d.%d"):format(i, k), { side }, {
          { ("side/s%05d-%d.txt"):format(i, k), "side\n" },
        })
      end
      head = commit("main", ("Merge side %d"):format(i), { head, side }, {})
      n = n + 4
    else
      head = commit("main", ("change %d: touch %s"):format(i, change[1][1]), { head }, change)
      n = n + 1
    end
  end
  s[#s + 1] = "reset refs/heads/side\nfrom :" .. head .. "\n"

  run({ "git", "fast-import", "--quiet" }, { stdin = table.concat(s) })
  run({ "git", "checkout", "-q", "main" })
  run({ "git", "tag", "v1.0", "HEAD~500" })

  -- The worktree: 1k+ changes across every group.
  for k = 0, MODIFIED - 1 do
    local path = repo .. "/" .. file(k % DIRS, math.floor(k / DIRS) % PER_DIR)
    vim.fn.writefile({ "modified", tostring(k) }, path)
  end
  for k = 0, DELETED - 1 do
    os.remove(repo .. "/" .. file(k % DIRS, PER_DIR - 1 - math.floor(k / DIRS)))
  end
  vim.fn.mkdir(repo .. "/new", "p")
  for k = 0, UNTRACKED - 1 do
    vim.fn.writefile({ "new" }, ("%s/new/n%03d.txt"):format(repo, k))
  end
  -- A few staged ones too.
  run({ "git", "add", "src/d00" })
end

-- ---------------------------------------------------------------------------
-- measurement helpers
-- ---------------------------------------------------------------------------

--- The longest gap between two turns of the event loop while `fn` runs,
--- i.e. the longest the UI would have been frozen. A 1 ms repeating timer
--- ticks on every loop iteration it can; a late tick is time spent inside
--- some other callback. (An idle handle would be more direct, but it keeps
--- the loop from ever polling, and vim.wait then never reaches its timeout.)
---@param fn fun(done: fun())
---@param timeout integer
---@return number max_block_ms, number elapsed_ms
local function max_block(fn, timeout)
  local timer = assert(vim.uv.new_timer())
  local last, worst = now(), 0
  timer:start(1, 1, function()
    local t = now()
    worst = math.max(worst, t - last)
    last = t
  end)
  local finished = false
  local t0 = now()
  fn(function()
    finished = true
  end)
  assert(
    vim.wait(timeout, function()
      return finished
    end, 1),
    "timed out"
  )
  local elapsed = now() - t0
  -- Let the scheduled redraws that follow the event run, and count them.
  local settle = now() + 100
  vim.wait(1000, function()
    return now() > settle
  end, 1)
  timer:stop()
  timer:close()
  return worst, elapsed
end

---@param xs number[]
local function stats(xs)
  local s = vim.deepcopy(xs)
  table.sort(s)
  return s[math.ceil(#s / 2)], s[#s]
end

local results = {}

---@param name string
---@param gate number
---@param first number  the cold run
---@param xs number[]   the warm runs
local function report(name, gate, first, xs)
  local median, max = stats(xs)
  local pass = median < gate
  results[#results + 1] = pass
  out(
    "%-36s cold %7.1f ms   median %7.1f ms   max %7.1f ms   gate < %d ms   %s",
    name,
    first,
    median,
    max,
    gate,
    pass and "PASS" or "FAIL"
  )
end

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------

local function main()
  if vim.fn.isdirectory(repo .. "/.git") == 0 then
    out("building %s ...", repo)
    local t = now()
    build()
    out("built in %.1f s", (now() - t) / 1000)
  end

  local count = vim.trim(run({ "git", "rev-list", "--count", "--all" }))
  local changed = #vim.split(vim.trim(run({ "git", "status", "--porcelain" })), "\n")
  out("repository: %s commits, %d changed files", count, changed)
  out(
    "nvim %s, git %s",
    tostring(vim.version()),
    vim.trim(run({ "git", "--version" })):match("[%d.]+")
  )
  out("")

  vim.o.columns, vim.o.lines = 200, 60
  vim.cmd.cd(repo)
  vim.cmd.edit(repo .. "/" .. file(1, 1))

  local gitvim = require("gitvim")
  gitvim.setup({ git = { collapsed = { "graph", "timeline" } } })
  local sidebar = require("gitvim.ui.sidebar")
  local state = require("gitvim.state")

  local function sidebar_buf()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].filetype == "gitvim" then
        return b
      end
    end
  end
  local function has_line(pattern)
    local b = sidebar_buf()
    if not b then
      return false
    end
    for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if l:find(pattern) then
        return true
      end
    end
    return false
  end
  local function lines()
    local b = sidebar_buf()
    return b and vim.api.nvim_buf_line_count(b) or 0
  end
  local function store()
    return state.get(require("gitvim.git.repo").active().root)
  end

  -- Gate 1: open the sidebar until SOURCE CONTROL shows the Changes group.
  local opens = {}
  for i = 0, RUNS do
    if i > 0 then
      sidebar.close()
      store():mark_dirty("status")
      store().status = nil
    end
    local t0 = now()
    gitvim.open("git")
    assert(
      vim.wait(10000, function()
        return has_line("Changes") and lines() > MODIFIED
      end, 1),
      "sidebar never showed the changes"
    )
    opens[#opens + 1] = now() - t0
  end
  report("sidebar open (status painted)", GATES.open, table.remove(opens, 1), opens)

  -- Gate 2: unfold GRAPH until its first page is on screen.
  local page = require("gitvim.config").options.graph.page_size
  local graphs = {}
  for i = 0, RUNS do
    local s = store()
    if i > 0 then
      s.collapsed["section:graph"] = true
      s.graph = nil
      sidebar.redraw()
    end
    local base = lines()
    local t0 = now()
    s.collapsed["section:graph"] = false
    sidebar.redraw()
    assert(
      vim.wait(10000, function()
        return s.graph and s.graph.loaded and lines() >= base + page
      end, 1),
      "graph never rendered"
    )
    graphs[#graphs + 1] = now() - t0
  end
  report("graph first page (" .. page .. " commits)", GATES.graph, table.remove(graphs, 1), graphs)

  -- Gate 3: refresh with everything open, watching for loop stalls.
  local blocks, totals = {}, {}
  for _ = 0, RUNS do
    local worst, elapsed = max_block(function(done)
      -- An explicit path: the current buffer is the sidebar, not a file.
      gitvim.refresh(repo, function(err)
        assert(not err, err and err.message)
        done()
      end)
    end, 10000)
    blocks[#blocks + 1] = worst
    totals[#totals + 1] = elapsed
  end
  report("refresh: longest main-loop block", GATES.block, table.remove(blocks, 1), blocks)
  local median = stats(totals)
  out("%-36s median %.1f ms (informational)", "refresh: status round trip", median)

  out("")
  local failed = vim.tbl_contains(results, false)
  out(failed and "FAILED" or "all gates passed")
  return failed and 1 or 0
end

local ok, code = xpcall(main, debug.traceback)
if not ok then
  io.stderr:write(tostring(code) .. "\n")
  code = 2
end
io.stdout:flush()
vim.cmd.cquit({ count = code, bang = true })
