--- config.lua: defaults, deep merge and validation.

local config = require("gitvim.config")

--- Capture vim.notify for the duration of `fn`.
---@param fn fun()
---@return string[]
local function captured(fn)
  local notify, messages = vim.notify, {}
  vim.notify = function(msg)
    table.insert(messages, msg)
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert.is_true(ok, tostring(err))
  return messages
end

describe("config.setup", function()
  after_each(function()
    config.setup({})
  end)

  it("returns the defaults when given nothing", function()
    local o = config.setup()
    assert.equals("left", o.sidebar.position)
    assert.equals(40, o.sidebar.width)
    assert.same({ "files", "search", "git", "buffers" }, o.sidebar.tabs)
  end)

  it("deep merges without dropping sibling keys", function()
    local o = config.setup({ sidebar = { width = 60 } })
    assert.equals(60, o.sidebar.width)
    assert.equals("left", o.sidebar.position)
    assert.equals("git", o.sidebar.default_tab)
  end)

  it("does not let one setup leak into the next", function()
    config.setup({ sidebar = { width = 60 } })
    assert.equals(40, config.setup({}).sidebar.width)
  end)

  it("replaces list options wholesale rather than appending", function()
    local o = config.setup({ sidebar = { tabs = { "git" }, default_tab = "git" } })
    assert.same({ "git" }, o.sidebar.tabs)
  end)

  it("reads a dotted path", function()
    config.setup({ graph = { page_size = 64 } })
    assert.equals(64, config.get("graph.page_size"))
    assert.is_nil(config.get("graph.nope"))
    assert.is_nil(config.get("nope.nope"))
  end)

  it("accepts extra icon names", function()
    local messages = captured(function()
      config.setup({ icons = { status = { submodule = "S" } } })
    end)
    assert.same({}, messages)
    assert.equals("S", config.options.icons.status.submodule)
    assert.equals("M", config.options.icons.status.modified)
  end)

  it("accepts arbitrary icon overrides", function()
    local messages = captured(function()
      config.setup({ icons = { overrides = { git = "G" } } })
    end)
    assert.same({}, messages)
    assert.equals("G", config.options.icons.overrides.git)
  end)

  it("warns about an unknown key instead of silently ignoring it", function()
    local messages = captured(function()
      config.setup({ sidebar = { widht = 60 } })
    end)

    assert.equals(1, #messages)
    assert.is_truthy(messages[1]:match("sidebar%.widht"))
  end)

  it("warns about an unknown top-level section", function()
    local messages = captured(function()
      config.setup({ sidbar = {} })
    end)
    assert.is_truthy(messages[1]:match("'sidbar'"))
  end)

  for name, opts in pairs({
    ["sidebar.position"] = { sidebar = { position = "middle" } },
    ["sidebar.width"] = { sidebar = { width = "wide" } },
    ["sidebar.tabs"] = { sidebar = { tabs = { "git", "nope" } } },
    ["graph.page_size"] = { graph = { page_size = 0 } },
    ["graph.date_format"] = { graph = { date_format = "fuzzy" } },
    ["review.layout"] = { review = { layout = "side-by-side" } },
    ["refresh.debounce"] = { refresh = { debounce = -1 } },
    ["keymaps.prefix"] = { keymaps = { prefix = false } },
    ["scm.groups"] = { scm = { groups = { "nope" } } },
    ["git.sections"] = { git = { sections = { "nope" } } },
    ["files.root"] = { files = { root = "home" } },
    ["buffers.sort"] = { buffers = { sort = "size" } },
    ["icons.style"] = { icons = { style = "emoji" } },
  }) do
    it("rejects a bad " .. name, function()
      assert.has_error(function()
        config.setup(opts)
      end)
    end)
  end

  it("rejects a default_tab that is not among the tabs", function()
    local ok, err = pcall(config.setup, { sidebar = { tabs = { "git" }, default_tab = "files" } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match("default_tab"))
  end)

  it("rejects a non-table opts", function()
    assert.has_error(function()
      config.setup("left")
    end)
  end)
end)
