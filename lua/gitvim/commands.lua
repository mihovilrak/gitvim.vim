--- The :GitVim user command and its completion.

local M = {}

local TABS = { "files", "search", "git", "buffers" }

--- A Source Control subcommand: runs `gitvim.actions[name]` against the
--- current buffer's repository.
---@param desc string
---@param name string
---@return gitvim.Subcommand
local function scm(desc, name)
  return {
    desc = desc,
    run = function()
      local actions = require("gitvim.actions")
      actions.in_current_repo(function()
        actions[name]()
      end)
    end,
  }
end

local COMMIT_FLAGS = { "--amend", "--signoff" }

---@class gitvim.Subcommand
---@field run fun(args: string[])
---@field desc string
---@field complete? fun(lead: string, args: string[]): string[]

--- Subcommand name -> handler. Filled in as phases land.
---@type table<string, gitvim.Subcommand>
local subcommands = {
  open = {
    desc = "open the sidebar, optionally on a tab",
    run = function(args)
      require("gitvim").open(args[1])
    end,
    complete = function()
      return TABS
    end,
  },
  close = {
    desc = "close the sidebar",
    run = function()
      require("gitvim").close()
    end,
  },
  toggle = {
    desc = "toggle the sidebar, optionally on a tab",
    run = function(args)
      require("gitvim").toggle(args[1])
    end,
    complete = function()
      return TABS
    end,
  },
  refresh = {
    desc = "re-read git status for the current repository",
    run = function()
      require("gitvim").refresh(function(err)
        if err then
          vim.notify(require("gitvim.git.cli").format_error(err), vim.log.levels.ERROR)
        end
      end)
    end,
  },
  blame = {
    desc = "toggle current-line blame",
    run = function()
      require("gitvim").toggle_blame()
    end,
  },
  ["blame-commit"] = {
    desc = "open the current line's commit in the Git graph",
    run = function()
      require("gitvim").open_blame_commit()
    end,
  },
  status = {
    desc = "echo a one-line summary of the current repository",
    run = function()
      require("gitvim").refresh(function(err, store)
        if err then
          vim.notify(require("gitvim.git.cli").format_error(err), vim.log.levels.ERROR)
          return
        end
        local repo = require("gitvim.git.repo").get(store.root)
        local groups = store:groups()
        vim.notify(
          ("gitvim: %s on %s — %d staged, %d changed, %d untracked"):format(
            vim.fn.fnamemodify(store.root, ":t"),
            repo and repo:head_label() or "?",
            #groups.staged,
            #groups.changes,
            #groups.untracked
          )
        )
      end)
    end,
  },
  stage = {
    desc = "stage the current file",
    run = function()
      require("gitvim.actions").stage_file()
    end,
  },
  unstage = {
    desc = "unstage the current file",
    run = function()
      require("gitvim.actions").unstage_file()
    end,
  },
  discard = {
    desc = "discard working-tree changes to the current file",
    run = function()
      require("gitvim.actions").discard_file()
    end,
  },
  review = {
    desc = "review the current file against the index, or against [rev]",
    run = function(args)
      local rev = args and args[1]
      require("gitvim.ui.review").open_file(nil, rev and { left_rev = rev } or nil)
    end,
    complete = function()
      return { "HEAD", "HEAD~1", "@{upstream}" }
    end,
  },
  ["stage-all"] = scm("stage every change", "stage_all"),
  ["unstage-all"] = scm("unstage everything", "unstage_all"),
  ["discard-all"] = scm("discard every working-tree change", "discard_all"),
  commit = {
    desc = "open the commit message editor (--amend, --signoff)",
    run = function(args)
      local opts = {}
      for _, arg in ipairs(args) do
        if arg == "--amend" then
          opts.amend = true
        elseif arg == "--signoff" then
          opts.signoff = true
        else
          vim.notify(("gitvim: unknown commit flag '%s'"):format(arg), vim.log.levels.ERROR)
          return
        end
      end
      local actions = require("gitvim.actions")
      actions.in_current_repo(function()
        actions.commit(opts)
      end)
    end,
    complete = function(_, args)
      return vim.tbl_filter(function(flag)
        return not vim.tbl_contains(args, flag)
      end, COMMIT_FLAGS)
    end,
  },
  fetch = scm("fetch from the remotes", "fetch"),
  pull = scm("pull the current branch", "pull"),
  push = scm("push the current branch, publishing it if needed", "push"),
  checkout = scm("switch to another local branch", "checkout"),
  health = {
    desc = "run :checkhealth gitvim",
    run = function()
      vim.cmd.checkhealth("gitvim")
    end,
  },
}

--- Names sorted, so completion order is stable rather than hash order.
---@return string[]
local function names()
  local out = vim.tbl_keys(subcommands)
  table.sort(out)
  return out
end

---@param list string[]
---@param lead string
---@return string[]
local function matching(list, lead)
  return vim.tbl_filter(function(name)
    return vim.startswith(name, lead)
  end, list)
end

--- Run a `:GitVim` invocation.
---
--- Takes the command table rather than a joined string, so a quoted or
--- space-containing argument survives the round trip from the lazy stub.
---@param cmd table  the argument of an nvim_create_user_command callback
function M.dispatch(cmd)
  local args = vim.deepcopy(cmd.fargs or {})
  local name = table.remove(args, 1) or "toggle"
  local sub = subcommands[name]
  if not sub then
    vim.notify(
      ("gitvim: unknown subcommand '%s' (try %s)"):format(name, table.concat(names(), ", ")),
      vim.log.levels.ERROR
    )
    return
  end
  sub.run(args)
end

--- Complete a `:GitVim` command line.
---
--- The first word completes subcommand names; anything after it is delegated
--- to that subcommand, so each one owns its own argument vocabulary.
---@param lead string   the word being completed
---@param line string   the whole command line so far
---@return string[]
function M.complete(lead, line)
  local words = vim.split(vim.trim(line), "%s+")
  -- words[1] is ":GitVim" itself; a trailing space means a new, empty word.
  local typed = #words - 1 + (line:sub(-1) == " " and 1 or 0)

  if typed <= 1 then
    return matching(names(), lead)
  end

  local sub = subcommands[words[2]]
  if not sub or not sub.complete then
    return {}
  end
  return matching(sub.complete(lead, vim.list_slice(words, 3)), lead)
end

function M.setup()
  vim.api.nvim_create_user_command("GitVim", M.dispatch, {
    nargs = "*",
    desc = "gitvim",
    complete = M.complete,
  })
end

return M
