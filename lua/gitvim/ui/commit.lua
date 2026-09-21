--- The commit message editor.
---
--- A small floating `gitcommit` buffer: ordinary multi-line editing, `<C-Enter>`
--- (or `<C-s>`, for terminals that cannot tell `<C-Enter>` from `<CR>`) to
--- commit, `q` / `<Esc>` to put it away. Whatever is typed is kept as the
--- repository's draft (D4: per repo), so closing the editor loses nothing.

local config = require("gitvim.config")

local M = {}

---@class gitvim.commit.Editor
---@field buf integer
---@field win integer
---@field repo gitvim.Repo
---@field opts gitvim.commit.Opts
---@field busy boolean

---@type gitvim.commit.Editor?
local current

---@param buf integer
---@return string
local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- Save the buffer as the draft. An amend edits HEAD's message rather than a
--- new one, so it never overwrites the draft.
---@param editor gitvim.commit.Editor
local function save_draft(editor)
  if editor.opts.amend or not vim.api.nvim_buf_is_valid(editor.buf) then
    return
  end
  require("gitvim.state").get(editor.repo.root).draft = text(editor.buf)
end

---@param opts gitvim.commit.Opts
---@param repo gitvim.Repo
---@return string
local function title(opts, repo)
  local what = opts.amend and "Amend" or "Commit"
  if opts.signoff then
    what = what .. " (signed off)"
  end
  return (" %s on %s · <C-Enter> commit · q close "):format(what, repo:head_label())
end

--- Close the editor, keeping the draft.
function M.close()
  local editor = current
  current = nil
  if not editor then
    return
  end
  save_draft(editor)
  if vim.api.nvim_win_is_valid(editor.win) then
    vim.api.nvim_win_close(editor.win, true)
  end
  if vim.api.nvim_buf_is_valid(editor.buf) then
    vim.api.nvim_buf_delete(editor.buf, { force = true })
  end
end

--- Commit the editor's contents.
---@param cb? fun(err?: gitvim.git.Error)
function M.submit(cb)
  local editor = current
  if not editor or editor.busy then
    return
  end
  local message = text(editor.buf)
  save_draft(editor)
  editor.busy = true

  require("gitvim.git.commit").commit(editor.repo.root, message, editor.opts, function(err)
    editor.busy = false
    if err then
      vim.notify(require("gitvim.git.cli").format_error(err), vim.log.levels.ERROR)
      if cb then
        cb(err)
      end
      return
    end

    if not editor.opts.amend then
      require("gitvim.state").get(editor.repo.root).draft = ""
    end
    -- Committed: drop the text before closing so it is not saved back.
    if vim.api.nvim_buf_is_valid(editor.buf) then
      vim.api.nvim_buf_set_lines(editor.buf, 0, -1, false, {})
    end
    local amend = editor.opts.amend
    if current == editor then
      editor.opts = { amend = true } -- save_draft is a no-op from here on
      M.close()
    end
    vim.notify(amend and "gitvim: amended HEAD" or "gitvim: committed")
    require("gitvim").refresh(editor.repo.root, function()
      if cb then
        cb(nil)
      end
    end)
  end)
end

---@return integer? buf  the editor buffer, if one is open
function M.buf()
  return current and current.buf or nil
end

---@param repo gitvim.Repo
---@param opts gitvim.commit.Opts
---@param lines string[]
local function create(repo, opts, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = math.min(math.max(60, 20), vim.o.columns - 4)
  local height = math.min(12, math.max(vim.o.lines - 6, 3))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = vim.o.winborder ~= "" and vim.o.winborder or "rounded",
    title = title(opts, repo),
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].spell = true
  -- Set after the window exists so ftplugins (textwidth, colorcolumn) apply.
  vim.bo[buf].filetype = "gitcommit"

  local editor = { buf = buf, win = win, repo = repo, opts = opts, busy = false }
  current = editor

  local map = function(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map({ "n", "i" }, "<C-CR>", function()
    M.submit()
  end, "gitvim: commit")
  map({ "n", "i" }, "<C-s>", function()
    M.submit()
  end, "gitvim: commit")
  map("n", "q", M.close, "gitvim: close commit editor")
  map("n", "<Esc>", M.close, "gitvim: close commit editor")

  local group = vim.api.nvim_create_augroup("gitvim_commit", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      if current == editor then
        save_draft(editor)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      -- Closed from outside (`:q`, `<C-w>c`): still keep the draft.
      if current == editor then
        save_draft(editor)
        current = nil
      end
    end,
  })

  if lines[1] == "" and #lines == 1 then
    vim.cmd.startinsert()
  end
end

--- Open the editor for `repo`, focusing an existing one if already open.
---@param repo gitvim.Repo
---@param opts? gitvim.commit.Opts
function M.open(repo, opts)
  opts = vim.tbl_extend("keep", opts or {}, { signoff = config.options.scm.signoff })
  if current then
    M.close()
  end

  local store = require("gitvim.state").get(repo.root)
  if opts.amend then
    require("gitvim.git.commit").last_message(repo.root, function(message)
      create(repo, opts, vim.split(message, "\n", { plain = true }))
    end)
    return
  end
  create(repo, opts, vim.split(store.draft or "", "\n", { plain = true }))
end

return M
