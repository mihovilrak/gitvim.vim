--- Deterministic throwaway git repositories for tests and manual QA.
---
--- Usage (tests):
---   local fixture = require("fixture")
---   local repo = fixture.build()
---   ... assertions against repo.root ...
---   repo:destroy()
---
--- Usage (manual QA):
---   nvim --headless -u tests/minimal_init.lua \
---     -c "lua print(require('fixture').build({ keep = true }).root)" -c "qa!"
---
--- The resulting topology is fixed, so assertions can be exact:
---
---   *  (HEAD -> main) merge branch 'feature'
---   |\
---   | * feat: add widget            [feature]
---   * | fix: tweak README           [main]
---   |/
---   * rename: docs/guide.md <- GUIDE.md
---   * chore: initial commit
---
--- Plus, left dirty in the working tree:
---   staged.lua     staged (A), then modified again in the worktree  -> XY = "AM"
---   modified.lua   tracked, modified, unstaged                      -> XY = " M"
---   deleted.lua    tracked, deleted, unstaged                       -> XY = " D"
---   "spaced ünicode.txt"  untracked                                 -> "?"
---   docs/guide.md  renamed in an earlier commit (exercises --follow)

local M = {}

---@class gitvim.Fixture
---@field root string
local Fixture = {}
Fixture.__index = Fixture

--- Run a git command in the fixture, failing loudly on a non-zero exit.
---@param args string[]
---@return string stdout
function Fixture:git(args)
  local cmd = { "git", "-C", self.root }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    error(("git %s failed (%d): %s"):format(table.concat(args, " "), res.code, res.stderr or ""))
  end
  return res.stdout or ""
end

---@param rel string
---@param content string
function Fixture:write(rel, content)
  local path = self.root .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(content)
  fd:close()
end

---@param rel string
function Fixture:remove(rel)
  os.remove(self.root .. "/" .. rel)
end

--- Resolve a ref to a full SHA.
---@param rev string
---@return string
function Fixture:sha(rev)
  return vim.trim(self:git({ "rev-parse", rev }))
end

function Fixture:destroy()
  if self.root and vim.fn.isdirectory(self.root) == 1 then
    vim.fn.delete(self.root, "rf")
  end
end

--- Build the fixture repository.
---@param opts? { keep?: boolean }
---@return gitvim.Fixture
function M.build(opts)
  opts = opts or {}

  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  local self = setmetatable({ root = root }, Fixture)

  self:git({ "init", "-b", "main" })
  self:git({ "config", "user.name", "gitvim test" })
  self:git({ "config", "user.email", "test@example.com" })
  self:git({ "config", "commit.gpgsign", "false" })

  -- 1. initial commit
  self:write("README.md", "# fixture\n")
  self:write("GUIDE.md", "guide, line one\nguide, line two\n")
  self:write("modified.lua", "return 1\n")
  self:write("deleted.lua", "return 2\n")
  self:git({ "add", "-A" })
  self:git({ "commit", "-m", "chore: initial commit" })

  -- 2. a rename, so timeline's --follow has something to follow.
  -- `git mv` does not create the destination directory.
  vim.fn.mkdir(root .. "/docs", "p")
  self:git({ "mv", "GUIDE.md", "docs/guide.md" })
  self:write("docs/guide.md", "guide, line one\nguide, line two\nguide, line three\n")
  self:git({ "add", "-A" })
  self:git({ "commit", "-m", "rename: docs/guide.md <- GUIDE.md" })

  -- 3. branch + merge, so the lane algorithm has a real fork to lay out
  self:git({ "checkout", "-b", "feature" })
  self:write("widget.lua", "return { widget = true }\n")
  self:git({ "add", "-A" })
  self:git({ "commit", "-m", "feat: add widget" })

  self:git({ "checkout", "main" })
  self:write("README.md", "# fixture\n\nA fixture repository.\n")
  self:git({ "add", "-A" })
  self:git({ "commit", "-m", "fix: tweak README" })

  self:git({ "merge", "--no-ff", "feature", "-m", "merge branch 'feature'" })

  -- 4. dirty working tree covering every status group
  self:write("staged.lua", "return 'staged'\n")
  self:git({ "add", "staged.lua" })
  self:write("staged.lua", "return 'staged, then modified'\n") -- XY == "AM"

  self:write("modified.lua", "return 1 + 1\n") -- XY == " M"
  self:remove("deleted.lua") -- XY == " D"
  self:write("spaced ünicode.txt", "paths are hard\n") -- untracked

  if opts.keep then
    print("fixture repo kept at: " .. root)
  end

  return self
end

--- Build a repo with an unresolved merge conflict (post-MVP conflict UI).
---@return gitvim.Fixture
function M.build_conflict()
  local self = M.build()

  self:git({ "checkout", "-b", "conflict-a" })
  self:write("conflicted.lua", "return 'a'\n")
  self:git({ "add", "-A" })
  self:git({ "commit", "-m", "conflict: side a" })

  self:git({ "checkout", "main" })
  self:write("conflicted.lua", "return 'b'\n")
  self:git({ "add", "-A" })
  self:git({ "commit", "-m", "conflict: side b" })

  -- Expected to fail: that is the point.
  vim.system({ "git", "-C", self.root, "merge", "conflict-a" }, { text = true }):wait()

  return self
end

return M
