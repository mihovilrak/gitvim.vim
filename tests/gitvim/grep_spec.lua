--- Search backends, asserted against ripgrep run by hand on the fixture.

local fixture = require("fixture")
local grep = require("gitvim.git.grep")
local helpers = require("helpers")

local await = helpers.await

--- Extra content with every case the toggles distinguish: case variants,
--- the pattern inside a longer word, and "." as a literal vs any character.
local CORPUS = table.concat({
  "Guide guide GUIDE guides",
  "foo.bar fooXbar foo.bar",
  "subguide_x guide-y",
  "",
}, "\n")

--- Every match as "path:lnum:col", 1-based col, from rg itself.
---@param root string
---@param q gitvim.grep.Query
---@return string[]
local function expected(root, q)
  local cmd = {
    "rg",
    "--no-config",
    "--hidden",
    "--glob",
    "!.git",
    "--no-heading",
    "--with-filename",
    "--line-number",
    "--column",
    "--only-matching",
    "--color",
    "never",
    q.case and "--case-sensitive" or "--ignore-case",
  }
  if q.word then
    cmd[#cmd + 1] = "--word-regexp"
  end
  if not q.regex then
    cmd[#cmd + 1] = "--fixed-strings"
  end
  for _, glob in ipairs(grep.globs(q.include)) do
    vim.list_extend(cmd, { "--glob", glob })
  end
  for _, glob in ipairs(grep.globs(q.exclude)) do
    vim.list_extend(cmd, { "--glob", "!" .. glob })
  end
  vim.list_extend(cmd, { "-e", q.pattern, "--", "." })
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(res.code <= 1, res.stderr)
  local out = {}
  for _, line in ipairs(vim.split(res.stdout, "\n", { trimempty = true })) do
    local path, lnum, col = line:match("^%./(.-):(%d+):(%d+):")
    out[#out + 1] = ("%s:%s:%s"):format(path, lnum, col)
  end
  table.sort(out)
  return out
end

---@param res gitvim.grep.Result
---@return string[]
local function flatten(res)
  local out = {}
  for _, file in ipairs(res.files) do
    for _, line in ipairs(file.lines) do
      for _, span in ipairs(line.spans) do
        out[#out + 1] = ("%s:%d:%d"):format(file.path, line.lnum, span.start + 1)
      end
    end
  end
  table.sort(out)
  return out
end

---@param root string
---@param q table
---@param backend gitvim.grep.Backend
---@return gitvim.grep.Result
local function search(root, q, backend)
  q = vim.tbl_extend("keep", q, {
    case = false,
    word = false,
    regex = false,
    include = "",
    exclude = "",
    replace = "",
  })
  local err, res = await(function(done)
    grep.run(root, q, { backend = backend }, done)
  end)
  assert.is_nil(err, err and err.message)
  return res
end

describe("grep", function()
  local repo

  before_each(function()
    repo = fixture.build()
    repo:write("search.txt", CORPUS)
  end)

  after_each(function()
    repo:destroy()
  end)

  it("splits glob lists", function()
    assert.same({ "*.lua", "src/**" }, grep.globs(" *.lua, ,src/** "))
    assert.same({}, grep.globs(""))
  end)

  it("locates -o matches in their line, skipping words in whole-word mode", function()
    assert.same(
      { { start = 0, stop = 3 }, { start = 8, stop = 11 } },
      grep.locate("foo bar foo", { "foo", "foo" }, false)
    )
    assert.same({ { start = 7, stop = 10 } }, grep.locate("foobar foo", { "foo" }, true))
  end)

  for _, backend in ipairs({ "rg", "git" }) do
    describe(backend, function()
      for _, case in ipairs({ false, true }) do
        for _, word in ipairs({ false, true }) do
          for _, regex in ipairs({ false, true }) do
            local name = ("case=%s word=%s regex=%s"):format(case, word, regex)
            it("matches rg with " .. name, function()
              for _, pattern in ipairs({ "guide", "foo.bar", "e," }) do
                local q = { pattern = pattern, case = case, word = word, regex = regex }
                local res = search(repo.root, q, backend)
                assert.same(expected(repo.root, q), flatten(res), pattern .. " " .. name)
                assert.equal(#flatten(res), res.count)
              end
            end)
          end
        end
      end

      it("passes include and exclude globs through", function()
        for _, q in ipairs({
          { pattern = "guide", include = "*.md" },
          { pattern = "guide", include = "docs" },
          { pattern = "guide", include = "docs/**" },
          { pattern = "guide", exclude = "*.md" },
          { pattern = "guide", exclude = "docs" },
          { pattern = "return", include = "*.lua", exclude = "widget.lua, staged.lua" },
        }) do
          local res = search(repo.root, q, backend)
          assert.same(expected(repo.root, q), flatten(res), vim.inspect(q))
        end
      end)

      it("groups matches by file and keeps the line text", function()
        local res = search(repo.root, { pattern = "guide", case = true }, backend)
        local file = vim.iter(res.files):find(function(f)
          return f.path == "search.txt"
        end)
        assert.equal(4, file.count)
        assert.equal(2, #file.lines)
        assert.equal("Guide guide GUIDE guides", file.lines[1].text)
        assert.equal(1, file.lines[1].lnum)
      end)

      it("stops at max_results and says so", function()
        local res = search(repo.root, { pattern = "guide", max = 3 }, backend)
        assert.equal(3, res.count)
        assert.is_true(res.truncated)
        local all = search(repo.root, { pattern = "guide" }, backend)
        assert.is_false(all.truncated)
      end)

      it("finds nothing without an error", function()
        local res = search(repo.root, { pattern = "no such text anywhere" }, backend)
        assert.equal(0, res.count)
        assert.same({}, res.files)
      end)

      it("never calls back once cancelled", function()
        local called = false
        local handle = grep.run(repo.root, {
          pattern = "guide",
          case = false,
          word = false,
          regex = false,
          include = "",
          exclude = "",
        }, { backend = backend }, function()
          called = true
        end)
        handle.cancel()
        vim.wait(300, function()
          return called
        end)
        assert.is_false(called)
      end)
    end)
  end

  it("expands capture groups through rg in regex mode", function()
    local res = search(
      repo.root,
      { pattern = "(foo)\\.(bar)", regex = true, case = true, replace = "${2}_$1" },
      "rg"
    )
    local line = res.files[1].lines[1]
    assert.equal("bar_foo fooXbar bar_foo", grep.substitute(line, "${2}_$1"))
  end)

  it("substitutes literally outside regex mode", function()
    local res = search(repo.root, { pattern = "foo.bar", case = true, replace = "$1" }, "git")
    assert.equal("$1 fooXbar $1", grep.substitute(res.files[1].lines[1], "$1"))
  end)
end)
