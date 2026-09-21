--- Icon lookup, with a nerd-font-free fallback.
---
--- Filetype glyphs come from mini.icons when it is present (LazyVim ships it),
--- otherwise nvim-web-devicons, otherwise nothing. `style = "ascii"` — or
--- `icons.enabled = false` — makes every glyph a plain-text stand-in, so the
--- sidebar stays legible in a terminal without a patched font.

local config = require("gitvim.config")

local M = {}

--- Nerd-font glyphs for the sidebar's own chrome. Filetype icons are not in
--- here: those are the icon provider's job.
local NERD = {
  files = "󰉋",
  search = "󰍉",
  git = "󰊢",
  buffers = "󰈔",
  chevron_open = "",
  chevron_closed = "",
  file = "󰈔",
  directory = "󰉋",
  directory_open = "󰝰",
  commit = "",
  ahead = "",
  behind = "",
  -- Buffers tab: the cursor marker and the unsaved-changes dot.
  current = "▸",
  modified = "●",
  -- SOURCE CONTROL row buttons.
  stage = "[+]",
  unstage = "[−]",
  discard = "[↩]",
  -- Review view hunk button (the other three are shared with the rows).
  expand = "[⤢]",
}

--- Text stand-ins, chosen to be the same display width or narrower.
local ASCII = {
  files = "",
  search = "[/]",
  git = "",
  buffers = "",
  chevron_open = "v",
  chevron_closed = ">",
  file = "",
  directory = "",
  directory_open = "",
  commit = "*",
  ahead = "^",
  behind = "v",
  current = ">",
  modified = "+",
  stage = "[+]",
  unstage = "[-]",
  discard = "[<]",
  expand = "[^]",
}

---@return boolean
local function nerd()
  local icons = config.options.icons
  if not icons.enabled then
    return false
  end
  if icons.style == "nerd" then
    return true
  end
  if icons.style == "ascii" then
    return false
  end
  -- "auto": LazyVim and kickstart both set this, and it is the only signal
  -- Neovim gives us about the terminal's font.
  return vim.g.have_nerd_font ~= false
end

--- A chrome glyph by name, honouring the configured style.
---
--- `icons.overrides.<name>` wins over both tables, so a single glyph can be
--- swapped without opting out of the whole set.
---@param name string
---@return string
function M.get(name)
  local override = config.options.icons.overrides[name]
  if type(override) == "string" then
    return override
  end
  return (nerd() and NERD[name] or ASCII[name]) or ""
end

--- The collapse chevron for a section or group header.
---@param open boolean
---@return string
function M.chevron(open)
  return M.get(open and "chevron_open" or "chevron_closed")
end

--- The status letter for an entry kind: `M`, `A`, `D`, `R`, `C`, `U`, `!`.
---
--- Always a letter, never a glyph — VS Code's letters are the thing users
--- actually read, and they need no font at all.
---@param kind gitvim.status.Kind
---@return string
function M.status(kind)
  return config.options.icons.status[kind] or "?"
end

--- The icon provider, resolved once and cached.
--- `false` means "looked, found nothing" so we do not retry on every row.
---@type false|fun(path: string, is_dir: boolean): string, string?
local provider

---@return false|fun(path: string, is_dir: boolean): string, string?
local function get_provider()
  if provider ~= nil then
    return provider
  end

  local ok, mini = pcall(require, "mini.icons")
  if ok then
    provider = function(path, is_dir)
      -- mini.icons' "directory" category wants a path; "file" resolves by
      -- basename and extension and falls back to a generic file glyph.
      local icon, hl = mini.get(is_dir and "directory" or "file", path)
      return icon, hl
    end
    return provider
  end

  local dev_ok, devicons = pcall(require, "nvim-web-devicons")
  if dev_ok then
    provider = function(path, is_dir)
      if is_dir then
        return NERD.directory, "GitVimIcon"
      end
      local icon, hl = devicons.get_icon(vim.fs.basename(path), nil, { default = true })
      return icon or NERD.file, hl
    end
    return provider
  end

  provider = false
  return provider
end

--- Filetype icon for a path.
---
--- Returns an empty string in ascii mode, which callers must treat as "render
--- no icon column" rather than "render a space".
---@param path string
---@param is_dir? boolean
---@return string icon, string hl
function M.file(path, is_dir)
  if not nerd() then
    return "", "GitVimIcon"
  end

  local fn = get_provider()
  if fn then
    local ok, icon, hl = pcall(fn, path, is_dir or false)
    if ok and icon and icon ~= "" then
      return icon, hl or "GitVimIcon"
    end
  end

  return is_dir and NERD.directory or NERD.file, "GitVimIcon"
end

--- Drop the cached provider. Tests only.
function M.reset()
  provider = nil
end

return M
