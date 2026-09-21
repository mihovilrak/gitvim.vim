--- The activity-tab registry, and the chrome every tab shares.
---
--- A tab is a plain table: a name, a winbar label, and a `rows(ctx)` function
--- returning `gitvim.render.Row[]`. It never touches a window or a buffer, so
--- a spec can assert on what a tab would draw without opening anything.

local icons = require("gitvim.ui.icons")

local M = {}

---@class gitvim.ui.TabCtx
---@field repo gitvim.Repo?     active repository, nil outside one
---@field store gitvim.Store?
---@field width integer         usable columns
---@field focused boolean       is the sidebar the current window

---@class gitvim.ui.Tab
---@field name gitvim.Tab
---@field title string                                  winbar text; "" means icon-only
---@field rows fun(ctx: gitvim.ui.TabCtx): gitvim.render.Row[]
---@field actions? table<string, fun(ctx: gitvim.ui.TabCtx, arg: any, row: gitvim.render.Row)>
---@field keys? table<string, string>                   lhs -> action name
---@field on_show? fun(ctx: gitvim.ui.TabCtx)
---@field on_hide? fun(ctx: gitvim.ui.TabCtx)

---@type table<string, gitvim.ui.Tab>
local loaded = {}

--- Load a tab module by name, once.
---@param name string
---@return gitvim.ui.Tab?
function M.get(name)
  if loaded[name] == nil then
    local ok, tab = pcall(require, "gitvim.ui.tabs." .. name)
    if not ok then
      vim.notify(("gitvim: no such tab '%s'"):format(name), vim.log.levels.ERROR)
      loaded[name] = false
      return nil
    end
    loaded[name] = tab
  end
  return loaded[name] or nil
end

--- Forget loaded tabs. Tests only.
function M.reset()
  loaded = {}
end

--- A panel title, e.g. `SOURCE CONTROL`.
---@param text string
---@param right? string  right-aligned trailing text, usually a count
---@return gitvim.render.Row
function M.title(text, right)
  ---@type gitvim.render.Row
  local row = { { text = text, hl = "GitVimTitle" } }
  if right and right ~= "" then
    row.virt = { { text = right .. " ", hl = "GitVimCount" } }
  end
  return row
end

--- A collapsible header: chevron, label, and an optional count.
---@param opts { text: string, open: boolean, action: string, arg?: any, count?: integer, hl?: string }
---@return gitvim.render.Row
function M.header(opts)
  local chevron = icons.chevron(opts.open)
  ---@type gitvim.render.Row
  local row = {
    { text = chevron, hl = "GitVimChevron" },
    { text = " " },
    { text = opts.text, hl = opts.hl or "GitVimSection" },
  }
  if opts.count and opts.count > 0 then
    row[#row + 1] = { text = " " }
    row[#row + 1] = { text = tostring(opts.count), hl = "GitVimCount" }
  end
  row.action = opts.action
  row.arg = opts.arg
  return row
end

--- A dimmed, indented line of explanatory text.
---@param text string
---@param indent? integer  spaces of leading indent (default 2)
---@return gitvim.render.Row
function M.hint(text, indent)
  return {
    { text = (" "):rep(indent or 2) .. text, hl = "GitVimHint" },
  }
end

--- A blank spacer line.
---@return gitvim.render.Row
function M.blank()
  return {}
end

--- The "you are not in a git repository" body, shared by every tab that needs
--- one, so the message never drifts between panels.
---@return gitvim.render.Row[]
function M.no_repo()
  return { M.blank(), M.hint("Not a git repository.") }
end

return M
