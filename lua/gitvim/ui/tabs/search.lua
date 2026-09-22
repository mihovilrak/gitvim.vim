--- The Search tab: VS Code's search form, in 40 columns.
---
--- Pattern (with the match-case / whole-word / regex toggles), Replace, and
--- the two glob filters, then the results: one collapsible header per file
--- and one row per matching line. With a replacement typed in, every match
--- row previews it -- the match struck out, the replacement beside it -- so
--- what `r` / `A` will write is on screen before it is written.
---
--- Searching is `gitvim.git.grep`; this file only decides when to run it.
--- Any change to the form re-runs the search, and a newer run cancels an
--- older one, so results never arrive out of order.

local config = require("gitvim.config")
local grep = require("gitvim.git.grep")
local state = require("gitvim.state")
local tabs = require("gitvim.ui.tabs")

local M = {
  name = "search",
  -- Icon-only in the winbar, like VS Code's activity bar.
  title = "",
}

--- Field key -> { label, placeholder }. Order is the render order.
local FIELDS = {
  { key = "pattern", label = "Pattern", placeholder = "Search" },
  { key = "replace", label = "Replace", placeholder = "Replace" },
  { key = "include", label = "files to include", placeholder = "e.g. *.lua, src/**" },
  { key = "exclude", label = "files to exclude", placeholder = "e.g. node_modules" },
}

--- The three buttons that live inside VS Code's search box. Two-letter labels
--- because they have to be legible without a nerd font and clickable without
--- a steady hand.
local TOGGLES = {
  { key = "case", text = "Aa", action = "toggle_case", desc = "Match case" },
  { key = "word", text = "ab", action = "toggle_word", desc = "Match whole word" },
  { key = "regex", text = ".*", action = "toggle_regex", desc = "Use regular expression" },
}

--- The label row for a field. The Pattern row carries the toggle buttons,
--- right-aligned so they sit where the search box's buttons do.
---@param ctx gitvim.ui.TabCtx
---@param label string
---@param with_toggles boolean
---@return gitvim.render.Row
local function label_row(ctx, label, with_toggles)
  ---@type gitvim.render.Row
  local row = { { text = " " .. label, hl = "GitVimLabel" } }
  if not with_toggles then
    return row
  end

  local search = ctx.store and ctx.store.search or {}
  local buttons = {}
  local width = 0
  for _, toggle in ipairs(TOGGLES) do
    local text = " " .. toggle.text .. " "
    width = width + #text
    buttons[#buttons + 1] = {
      text = text,
      hl = search[toggle.key] and "GitVimToggleOn" or "GitVimToggleOff",
      action = toggle.action,
    }
  end

  local pad = ctx.width - #label - 1 - width - 1
  row[#row + 1] = { text = (" "):rep(math.max(pad, 1)) }
  vim.list_extend(row, buttons)
  return row
end

--- The value row: what the user typed, or a dimmed placeholder.
---@param value string
---@param placeholder string
---@param key string
---@return gitvim.render.Row
local function value_row(value, placeholder, key)
  local empty = value == nil or value == ""
  return {
    { text = "  " },
    {
      text = empty and placeholder or value,
      hl = empty and "GitVimFieldEmpty" or "GitVimField",
      action = "edit",
      arg = key,
    },
    action = "edit",
    arg = key,
  }
end

-- ---------------------------------------------------------------------------
-- running
-- ---------------------------------------------------------------------------

--- The search in flight, per repo root.
---@type table<string, gitvim.grep.Handle>
local running = {}

--- Run the form's search for a store, replacing whatever ran before.
---
--- An empty pattern clears the results instead: VS Code's list empties as
--- the box does.
---@param store gitvim.Store
---@param cb? fun()  after the results are in (tests)
function M.run(store, cb)
  local root = store.root
  if running[root] then
    running[root].cancel()
    running[root] = nil
  end

  local query = vim.deepcopy(store.search)
  if query.pattern == "" then
    store.results = nil
    state.emit("search", { root = root })
    if cb then
      vim.schedule(cb)
    end
    return
  end

  local previous = store.results
  store.results = {
    query = query,
    running = true,
    -- A re-run keeps the files the user folded folded.
    collapsed = previous and previous.collapsed or {},
    result = previous and previous.result or nil,
  }
  local results = store.results
  state.emit("search", { root = root })

  running[root] = grep.run(root, query --[[@as gitvim.grep.Query]], nil, function(err, result)
    running[root] = nil
    results.running = false
    results.result = result
    results.err = err and err.message or nil
    state.emit("search", { root = root })
    if cb then
      cb()
    end
  end)
end

--- Re-run after the form changed, when there is somewhere to run it.
---@param ctx gitvim.ui.TabCtx
local function rerun(ctx)
  if ctx.repo and ctx.store then
    M.run(ctx.store)
  end
end

-- ---------------------------------------------------------------------------
-- replacing
-- ---------------------------------------------------------------------------

--- Write the replacement into one file, through a buffer.
---
--- Going through a buffer rather than the file on disk is what makes it
--- undoable: every changed line lands in one `nvim_buf_set_lines`, so a
--- single `u` in that file takes the whole replace back. A buffer the user
--- had unsaved edits in is changed but left unsaved; any other is written.
---
--- A line whose text no longer matches what the search saw is skipped, not
--- guessed at: the byte offsets would point somewhere else now.
---@param root string
---@param file gitvim.grep.File
---@param replace string
---@param only? integer  a single line number, instead of every match in the file
---@return integer replaced matches actually replaced
function M.apply_file(root, file, replace, only)
  local buf = vim.fn.bufadd(root .. "/" .. file.path)
  vim.fn.bufload(buf)
  -- A hidden, unlisted buffer would take its undo history with it when
  -- wiped; listing it keeps the replace reachable from `:ls` and `u`.
  vim.bo[buf].buflisted = true
  local was_modified = vim.bo[buf].modified

  local changed, first, last, count = {}, nil, nil, 0
  for _, line in ipairs(file.lines) do
    if not only or line.lnum == only then
      local current = vim.api.nvim_buf_get_lines(buf, line.lnum - 1, line.lnum, false)[1]
      if current == line.text then
        changed[line.lnum] = grep.substitute(line, replace)
        first = math.min(first or line.lnum, line.lnum)
        last = math.max(last or line.lnum, line.lnum)
        count = count + #line.spans
      end
    end
  end
  if not first then
    return 0
  end

  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  for lnum, text in pairs(changed) do
    lines[lnum - first + 1] = text
  end
  vim.api.nvim_buf_set_lines(buf, first - 1, last, false, lines)

  if not was_modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent update")
    end)
  end
  return count
end

--- Replace matches, asking first when `search.confirm_replace` says to.
---@param ctx gitvim.ui.TabCtx
---@param files gitvim.grep.File[]
---@param only? integer  one line of the single file in `files`
local function replace(ctx, files, only)
  local store, results = ctx.store, ctx.store and ctx.store.results
  if not (ctx.repo and store and results and results.result) then
    return
  end
  if results.running then
    vim.notify("gitvim: search is still running", vim.log.levels.WARN)
    return
  end
  local text = store.search.replace
  -- ripgrep expanded the replacement when the search ran; a different one
  -- typed since would need expanding again.
  if text ~= results.query.replace then
    M.run(store)
    return
  end

  local count = 0
  for _, file in ipairs(files) do
    for _, line in ipairs(file.lines) do
      if not only or line.lnum == only then
        count = count + #line.spans
      end
    end
  end
  if count == 0 then
    return
  end

  local root = store.root
  local function go()
    local done = 0
    for _, file in ipairs(files) do
      local ok, n = pcall(M.apply_file, root, file, text, only)
      if ok then
        done = done + n
      else
        vim.notify(("gitvim: replace in %s failed: %s"):format(file.path, n), vim.log.levels.ERROR)
      end
    end
    if done < count then
      vim.notify(
        ("gitvim: replaced %d of %d matches; the rest changed since the search"):format(done, count),
        vim.log.levels.WARN
      )
    end
    M.run(store)
    require("gitvim").refresh(root)
  end

  -- One line is previewed right there in its row; asking about it too would
  -- only be noise. A file or the whole list is worth the question.
  if only or not config.options.search.confirm_replace then
    go()
    return
  end
  local prompt = ("Replace %d match%s in %d file%s with '%s'?"):format(
    count,
    count == 1 and "" or "es",
    #files,
    #files == 1 and "" or "s",
    text
  )
  vim.ui.select({ "Replace", "Cancel" }, { prompt = prompt }, function(choice)
    if choice == "Replace" then
      go()
    end
  end)
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

--- Leading context kept before a line's first match, in bytes, when the
--- line is cut so the match is visible in a narrow sidebar.
local CONTEXT = 12

--- One matching line: the text around the matches, each match highlighted
--- and, with a replacement typed, followed by its preview.
---@param file gitvim.grep.File
---@param line gitvim.grep.Line
---@param preview? string  the replacement, nil for none
---@return gitvim.render.Row
local function match_row(file, line, preview)
  local text = line.text
  -- Indentation is noise in a 40-column list, and a match far along a long
  -- line would sit off the right edge: start just before it instead.
  local from = (text:find("%S") or 1)
  local first = line.spans[1]
  local lead = ""
  if first and first.start + 1 - from > CONTEXT then
    local cut = first.start + 1 - CONTEXT
    from = cut + vim.str_utf_start(text, cut)
    lead = "…"
  end
  if first then
    from = math.min(from, first.start + 1)
  end

  ---@type gitvim.render.Row
  local row = { { text = "    " .. lead } }
  local pos = from
  for _, span in ipairs(line.spans) do
    local open = { path = file.path, lnum = line.lnum, col = span.start }
    if span.start + 1 > pos then
      row[#row + 1] = { text = text:sub(pos, span.start) }
    end
    local matched = text:sub(span.start + 1, span.stop)
    if preview then
      row[#row + 1] =
        { text = matched, hl = "GitVimMatchRemoved", action = "open_match", arg = open }
      row[#row + 1] =
        { text = span.rep or preview, hl = "GitVimReplace", action = "open_match", arg = open }
    else
      row[#row + 1] = { text = matched, hl = "GitVimMatch", action = "open_match", arg = open }
    end
    pos = span.stop + 1
  end
  row[#row + 1] = { text = text:sub(pos) }

  row.action = "open_match"
  row.arg = { path = file.path, lnum = line.lnum, col = first and first.start or 0 }
  row.data = { type = "search_match", path = file.path, lnum = line.lnum }
  row.virt = { { text = tostring(line.lnum) .. " ", hl = "GitVimCount" } }
  return row
end

--- The results below the form.
---@param store gitvim.Store
---@param rows gitvim.render.Row[]
local function result_rows(store, rows)
  local results = store.results
  if not results then
    rows[#rows + 1] = tabs.hint("<CR> edits a field, <M-c>/<M-w>/<M-r> toggle.", 1)
    return
  end
  if results.err then
    rows[#rows + 1] = { { text = " " .. results.err, hl = "GitVimError" } }
    return
  end
  local result = results.result
  if not result then
    rows[#rows + 1] = tabs.hint("Searching…", 1)
    return
  end
  if result.count == 0 then
    rows[#rows + 1] = tabs.hint(results.running and "Searching…" or "No results.", 1)
    return
  end

  local summary = ("%d result%s in %d file%s"):format(
    result.count,
    result.count == 1 and "" or "s",
    #result.files,
    #result.files == 1 and "" or "s"
  )
  ---@type gitvim.render.Row
  local head = { { text = " " .. summary, hl = "GitVimHint" } }
  if result.truncated then
    head[#head + 1] = { text = " (capped)", hl = "GitVimHint" }
  end
  if results.running then
    head[#head + 1] = { text = " …", hl = "GitVimHint" }
  end
  local preview = store.search.replace ~= "" and store.search.replace or nil
  if preview then
    head[#head + 1] = { text = "  " }
    head[#head + 1] = { text = "[replace all]", hl = "GitVimButtonActive", action = "replace_all" }
  end
  rows[#rows + 1] = head

  for _, file in ipairs(result.files) do
    local open = not results.collapsed[file.path]
    local header = tabs.header({
      text = file.path,
      open = open,
      action = "toggle_file",
      arg = file.path,
      count = file.count,
      hl = "GitVimFile",
    })
    header.data = { type = "search_file", path = file.path }
    rows[#rows + 1] = header
    if open then
      for _, line in ipairs(file.lines) do
        rows[#rows + 1] = match_row(file, line, preview)
      end
    end
  end
end

---@param ctx gitvim.ui.TabCtx
---@return gitvim.render.Row[]
function M.rows(ctx)
  if not ctx.store then
    return tabs.no_repo()
  end

  local search = ctx.store.search
  local rows = { tabs.title("SEARCH") }

  for _, field in ipairs(FIELDS) do
    rows[#rows + 1] = tabs.blank()
    rows[#rows + 1] = label_row(ctx, field.label, field.key == "pattern")
    rows[#rows + 1] = value_row(search[field.key], field.placeholder, field.key)
  end

  rows[#rows + 1] = tabs.blank()
  result_rows(ctx.store, rows)

  return rows
end

--- The file a results row belongs to.
---@param ctx gitvim.ui.TabCtx
---@param path string
---@return gitvim.grep.File?
local function file_for(ctx, path)
  local result = ctx.store and ctx.store.results and ctx.store.results.result
  for _, file in ipairs(result and result.files or {}) do
    if file.path == path then
      return file
    end
  end
end

---@param key string
---@return string
local function label_for(key)
  for _, field in ipairs(FIELDS) do
    if field.key == key then
      return field.label
    end
  end
  return key
end

---@param ctx gitvim.ui.TabCtx
---@param key string
local function toggle(ctx, key)
  if ctx.store then
    ctx.store.search[key] = not ctx.store.search[key]
  end
end

M.actions = {
  --- Edit a field. `vim.ui.input` so the prompt honours whatever the user's
  --- config replaced it with (dressing.nvim, snacks.input, the built-in).
  ---@param ctx gitvim.ui.TabCtx
  ---@param key string
  edit = function(ctx, key)
    if not ctx.store or not key or ctx.store.search[key] == nil then
      return
    end
    vim.ui.input({
      prompt = label_for(key) .. ": ",
      default = ctx.store.search[key],
    }, function(input)
      if input == nil then
        return -- cancelled; leave the field alone
      end
      ctx.store.search[key] = input
      rerun(ctx)
      require("gitvim.ui.sidebar").redraw()
    end)
  end,

  toggle_case = function(ctx)
    toggle(ctx, "case")
    rerun(ctx)
  end,
  toggle_word = function(ctx)
    toggle(ctx, "word")
    rerun(ctx)
  end,
  toggle_regex = function(ctx)
    toggle(ctx, "regex")
    rerun(ctx)
  end,

  ---@param ctx gitvim.ui.TabCtx
  clear = function(ctx)
    if ctx.store then
      ctx.store.search.pattern = ""
      ctx.store.search.replace = ""
      rerun(ctx)
    end
  end,

  --- Search again: the files changed, or the last run was capped.
  ---@param ctx gitvim.ui.TabCtx
  refresh = function(ctx)
    rerun(ctx)
  end,

  ---@param ctx gitvim.ui.TabCtx
  ---@param path string
  toggle_file = function(ctx, path)
    local results = ctx.store and ctx.store.results
    if results and path then
      results.collapsed[path] = not results.collapsed[path] or nil
    end
  end,

  --- Open a match in the editor window, cursor on the match.
  ---@param ctx gitvim.ui.TabCtx
  ---@param arg { path: string, lnum: integer, col: integer }
  open_match = function(ctx, arg)
    if ctx.repo and arg then
      require("gitvim.ui.sidebar").open_file(
        ctx.repo.root .. "/" .. arg.path,
        { arg.lnum, arg.col }
      )
    end
  end,

  --- `r`: the line under the cursor, or every match in the file whose
  --- header it is.
  ---@param ctx gitvim.ui.TabCtx
  ---@param row gitvim.render.Row
  replace = function(ctx, _, row)
    local data = row and row.data
    if not (data and (data.type == "search_match" or data.type == "search_file")) then
      return
    end
    local file = file_for(ctx, data.path)
    if file then
      replace(ctx, { file }, data.type == "search_match" and data.lnum or nil)
    end
  end,

  ---@param ctx gitvim.ui.TabCtx
  replace_all = function(ctx)
    local result = ctx.store and ctx.store.results and ctx.store.results.result
    if result then
      replace(ctx, result.files)
    end
  end,
}

--- `<M-c>` / `<M-w>` / `<M-r>` are VS Code's own bindings for the three
--- toggles, so the muscle memory transfers.
M.keys = {
  ["<M-c>"] = "toggle_case",
  ["<M-w>"] = "toggle_word",
  ["<M-r>"] = "toggle_regex",
  ["i"] = "edit",
  ["<C-l>"] = "clear",
  ["r"] = "replace",
  ["A"] = "replace_all",
}

return M
