--- doc/gitvim.txt stays in step with the code: every highlight group, config
--- section and subcommand is documented, and every |link| resolves.

local config = require("gitvim.config")
local hl = require("gitvim.ui.hl")

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local path = vim.fs.joinpath(root, "doc", "gitvim.txt")

---@return string
local function read()
  local fd = assert(io.open(path, "r"))
  local text = fd:read("*a")
  fd:close()
  return text
end

--- Every `*tag*` the help file defines.
---@param text string
---@return table<string, integer> tag -> count
local function defined(text)
  local tags = {}
  for tag in text:gmatch("%*([^%s*|]+)%*") do
    tags[tag] = (tags[tag] or 0) + 1
  end
  return tags
end

--- Neovim's own help tags, for links like |vim.notify()|.
---@return table<string, true>
local function runtime_tags()
  local tags = {}
  local file = vim.fs.joinpath(vim.env.VIMRUNTIME, "doc", "tags")
  for line in io.lines(file) do
    tags[line:match("^[^\t]+")] = true
  end
  return tags
end

describe("doc/gitvim.txt", function()
  local text = read()
  local tags = defined(text)

  it("defines no tag twice", function()
    for tag, count in pairs(tags) do
      assert.are.equal(1, count, tag)
    end
  end)

  it("resolves every |link|", function()
    local rt = runtime_tags()
    for line in vim.gsplit(text, "\n", { plain = true }) do
      for link in line:gmatch("|([^%s|]+)|") do
        assert.is_true(tags[link] ~= nil or rt[link] ~= nil, "unresolved |" .. link .. "|")
      end
    end
  end)

  it("keeps lines within 78 columns", function()
    local n = 0
    for line in vim.gsplit(text, "\n", { plain = true }) do
      n = n + 1
      assert.is_true(vim.fn.strdisplaywidth(line) <= 78, ("line %d is too long"):format(n))
    end
  end)

  it("lists every highlight group", function()
    for _, group in ipairs(hl.groups()) do
      assert.is_truthy(text:find(group, 1, true), group)
    end
  end)

  it("tags every config section", function()
    for section in pairs(config.defaults) do
      assert.are.equal(1, tags["gitvim-config-" .. section], section)
    end
  end)

  it("tags every :GitVim subcommand", function()
    for _, name in ipairs(require("gitvim.commands").complete("", "GitVim ")) do
      assert.are.equal(1, tags[":GitVim-" .. name], name)
    end
  end)

  it("documents every public function", function()
    for name, value in pairs(require("gitvim")) do
      if type(value) == "function" and not vim.startswith(name, "_") then
        assert.are.equal(1, tags["gitvim." .. name .. "()"], name)
      end
    end
  end)

  it("carries the same version as the code", function()
    assert.is_truthy(text:find("Version:  " .. require("gitvim").version .. "\n", 1, true))
  end)
end)
