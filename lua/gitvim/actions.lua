--- Source Control operations, as the user triggers them.
---
--- The sidebar buttons, the sidebar keys, the `<leader>g` maps and `:GitVim`
--- all land here, so each operation confirms, reports and refreshes the same
--- way whichever door it came through. The `gitvim.git.*` modules below this
--- one only run git; this layer adds the prompts and the refresh.

local cli = require("gitvim.git.cli")
local config = require("gitvim.config")

local M = {}

---@alias gitvim.actions.Done fun(err?: gitvim.git.Error)

--- Report a failure, re-read status either way, then hand the error on.
---@param root string
---@param cb? gitvim.actions.Done
---@return gitvim.actions.Done
local function finish(root, cb)
  return function(err)
    if err then
      vim.notify(cli.format_error(err), vim.log.levels.ERROR)
    end
    require("gitvim").refresh(root, function()
      if cb then
        cb(err)
      end
    end)
  end
end

--- The repository to act on: the one the sidebar shows.
---@return gitvim.Repo?
local function active()
  local repo = require("gitvim.git.repo").active()
  if not repo then
    vim.notify("gitvim: not in a git repository", vim.log.levels.WARN)
  end
  return repo
end

--- Run `fn` against the repository of the current buffer, or the sidebar's
--- repository when the current buffer is not a file (the sidebar itself, a
--- terminal). The repository is re-detected and its status re-read first, so
--- `:GitVim commit` in a freshly opened file works before the sidebar has
--- ever been shown.
---@param fn fun(repo: gitvim.Repo)
function M.in_current_repo(fn)
  local path = vim.api.nvim_buf_get_name(0)
  local repo_mod = require("gitvim.git.repo")
  if path == "" or vim.bo.buftype ~= "" then
    local repo = repo_mod.active()
    path = repo and repo.root or vim.uv.cwd()
  end
  require("gitvim").refresh(path, function(err, store)
    if err then
      vim.notify(cli.format_error(err), vim.log.levels.ERROR)
      return
    end
    fn(assert(repo_mod.get(store.root)))
  end)
end

--- Ask before destroying work, unless the user opted out.
---@param prompt string
---@param yes string
---@param fn fun()
local function confirm(prompt, yes, fn)
  if not config.options.scm.confirm_discard then
    fn()
    return
  end
  vim.ui.select({ yes, "Cancel" }, { prompt = prompt }, function(choice)
    if choice == yes then
      fn()
    end
  end)
end

-- ---------------------------------------------------------------------------
-- stage / unstage / discard
-- ---------------------------------------------------------------------------

---@param entries gitvim.status.Entry[]
---@param cb? gitvim.actions.Done
function M.stage(entries, cb)
  local repo = active()
  if repo then
    require("gitvim.git.stage").stage(repo.root, entries, finish(repo.root, cb))
  end
end

---@param entries gitvim.status.Entry[]
---@param cb? gitvim.actions.Done
function M.unstage(entries, cb)
  local repo = active()
  if repo then
    require("gitvim.git.stage").unstage(repo.root, entries, finish(repo.root, cb))
  end
end

---@param entries gitvim.status.Entry[]
---@param cb? gitvim.actions.Done
function M.discard(entries, cb)
  local repo = active()
  if not repo or #entries == 0 then
    return
  end
  local prompt
  if #entries == 1 then
    local entry = entries[1]
    prompt = entry.group == "untracked" and ("Delete untracked file '%s'?"):format(entry.path)
      or ("Discard changes to '%s'?"):format(entry.path)
  else
    prompt = ("Discard changes to %d files?"):format(#entries)
  end
  confirm(prompt, "Discard", function()
    require("gitvim.git.stage").discard(repo.root, entries, finish(repo.root, cb))
  end)
end

---@param cb? gitvim.actions.Done
function M.stage_all(cb)
  local repo = active()
  if repo then
    require("gitvim.git.stage").stage_all(repo.root, finish(repo.root, cb))
  end
end

---@param cb? gitvim.actions.Done
function M.unstage_all(cb)
  local repo = active()
  if repo then
    require("gitvim.git.stage").unstage_all(repo.root, finish(repo.root, cb))
  end
end

---@param cb? gitvim.actions.Done
function M.discard_all(cb)
  local repo = active()
  if not repo then
    return
  end
  confirm("Discard ALL working-tree changes and delete untracked files?", "Discard all", function()
    require("gitvim.git.stage").discard_all(repo.root, finish(repo.root, cb))
  end)
end

--- The status entries of one sidebar group, e.g. to stage all of Untracked.
---@param group gitvim.status.Group
---@return gitvim.status.Entry[]
function M.group_entries(group)
  local store = require("gitvim.state").active()
  return store and store:groups()[group] or {}
end

--- The entries for a file on disk, in the groups given (all groups if nil).
---@param path string  absolute
---@param groups? gitvim.status.Group[]
---@return gitvim.status.Entry[]
function M.file_entries(path, groups)
  local repo = require("gitvim.git.repo").active()
  local store = require("gitvim.state").active()
  if not repo or not store or not store.status then
    return {}
  end
  path = vim.fs.normalize(path)
  local prefix = repo.root .. "/"
  if path:sub(1, #prefix) ~= prefix then
    return {}
  end
  local rel = path:sub(#prefix + 1)
  local out = {}
  for _, entry in ipairs(store.status.entries) do
    if entry.path == rel and (not groups or vim.tbl_contains(groups, entry.group)) then
      out[#out + 1] = entry
    end
  end
  return out
end

--- Run a file-level operation on the current buffer's file.
---@param fn fun(entries: gitvim.status.Entry[])
---@param groups gitvim.status.Group[]
---@param what string  for the "nothing to do" message
local function on_current_file(fn, groups, what)
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    return
  end
  -- Status may be stale (the buffer was just written): re-read it first.
  require("gitvim").refresh(path, function(err)
    if err then
      vim.notify(cli.format_error(err), vim.log.levels.ERROR)
      return
    end
    local entries = M.file_entries(path, groups)
    if #entries == 0 then
      vim.notify(("gitvim: %s has nothing to %s"):format(vim.fn.fnamemodify(path, ":t"), what))
      return
    end
    fn(entries)
  end)
end

function M.stage_file()
  on_current_file(M.stage, { "changes", "untracked", "merge" }, "stage")
end

function M.unstage_file()
  on_current_file(M.unstage, { "staged" }, "unstage")
end

function M.discard_file()
  on_current_file(M.discard, { "changes", "untracked" }, "discard")
end

-- ---------------------------------------------------------------------------
-- commit
-- ---------------------------------------------------------------------------

--- Open the commit message editor.
---@param opts? gitvim.commit.Opts
function M.commit(opts)
  local repo = active()
  if repo then
    require("gitvim.ui.commit").open(repo, opts)
  end
end

-- ---------------------------------------------------------------------------
-- remotes
-- ---------------------------------------------------------------------------

---@param cb? gitvim.actions.Done
function M.fetch(cb)
  local repo = active()
  if repo then
    require("gitvim.git.remote").fetch(repo.root, function(err)
      require("gitvim").refresh(repo.root, function()
        if cb then
          cb(err)
        end
      end)
    end)
  end
end

---@param cb? gitvim.actions.Done
function M.pull(cb)
  local repo = active()
  if repo then
    require("gitvim.git.remote").pull(repo.root, function(err)
      require("gitvim").refresh(repo.root, function()
        if cb then
          cb(err)
        end
      end)
    end)
  end
end

---@param cb? gitvim.actions.Done
function M.push(cb)
  local repo = active()
  if repo then
    require("gitvim.git.remote").push(repo, function(err)
      require("gitvim").refresh(repo.root, function()
        if cb then
          cb(err)
        end
      end)
    end)
  end
end

--- Pick a local branch and switch to it.
---@param cb? gitvim.actions.Done
function M.checkout(cb)
  local repo = active()
  if not repo then
    return
  end
  cli.run(
    { "for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads" },
    { cwd = repo.root },
    function(err, res)
      if err then
        vim.notify(cli.format_error(err), vim.log.levels.ERROR)
        return
      end
      local branches = vim.tbl_filter(function(name)
        return name ~= repo.head
      end, vim.split(vim.trim(res.stdout), "\n", { trimempty = true }))
      if #branches == 0 then
        vim.notify("gitvim: no other branch to check out")
        return
      end
      vim.ui.select(branches, { prompt = "Check out branch" }, function(branch)
        if branch then
          cli.run({ "switch", branch }, { cwd = repo.root }, finish(repo.root, cb))
        end
      end)
    end
  )
end

return M
