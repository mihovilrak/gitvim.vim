--- Current-line blame and navigation from blame to the Git graph.

local bridge = require("gitvim.buffer.bridge")

local M = {}

local ZERO_SHA = "^0+$"

---@param value? boolean
---@return boolean? enabled
function M.toggle(value)
  local enabled = bridge.toggle_blame(value)
  if enabled == nil then
    vim.notify("gitvim: gitsigns.nvim is unavailable", vim.log.levels.WARN)
  end
  return enabled
end

--- Select the blamed commit for the current line in the GRAPH section.
---
--- Phase 7 consumes `store.graph_commit` when its renderer arrives. Until
--- then the expanded section still exposes the selected revision, making the
--- navigation contract useful rather than silently dropping the request.
---@param bufnr? integer
function M.open_commit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local info = bridge.blame_info(bufnr)
  local sha = info and (info.sha or info.abbrev_sha)
  if type(sha) ~= "string" or sha == "" or sha:match(ZERO_SHA) then
    vim.notify("gitvim: no committed blame for the current line", vim.log.levels.WARN)
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  require("gitvim").refresh(path ~= "" and path or nil, function(err, store)
    if err or not store then
      local message = err and require("gitvim.git.cli").format_error(err)
        or "gitvim: could not find the file's repository"
      vim.notify(message, vim.log.levels.ERROR)
      return
    end

    store.graph_commit = sha
    store.collapsed["section:graph"] = false
    local sidebar = require("gitvim.ui.sidebar")
    sidebar.open("git")
    sidebar.reveal("toggle_section", "graph")
  end)
end

return M
