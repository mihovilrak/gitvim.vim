--- commands.lua: :GitVim dispatch and completion.

local commands = require("gitvim.commands")

describe("commands.complete", function()
  it("completes subcommand names, sorted", function()
    local names = commands.complete("", "GitVim ")
    assert.is_true(vim.tbl_contains(names, "open"))
    assert.is_true(vim.tbl_contains(names, "toggle"))
    assert.same(vim.deepcopy(names), vim.fn.sort(vim.deepcopy(names)))
  end)

  it("filters by the leading text", function()
    assert.same({ "toggle" }, commands.complete("to", "GitVim to"))
  end)

  it("completes a subcommand's own arguments", function()
    assert.same({ "files", "search", "git", "buffers" }, commands.complete("", "GitVim open "))
    assert.same({ "search" }, commands.complete("se", "GitVim open se"))
  end)

  it("offers nothing after a subcommand that takes no arguments", function()
    assert.same({}, commands.complete("", "GitVim close "))
  end)

  it("offers nothing for an unknown subcommand", function()
    assert.same({}, commands.complete("", "GitVim frobnicate "))
  end)
end)

describe("commands.dispatch", function()
  it("reports an unknown subcommand and lists the valid ones", function()
    local notify, messages = vim.notify, {}
    vim.notify = function(msg, level)
      table.insert(messages, { msg = msg, level = level })
    end
    commands.dispatch({ fargs = { "frobnicate" } })
    vim.notify = notify

    assert.equals(1, #messages)
    assert.equals(vim.log.levels.ERROR, messages[1].level)
    assert.is_truthy(messages[1].msg:match("unknown subcommand 'frobnicate'"))
    assert.is_truthy(messages[1].msg:match("toggle"))
  end)

  it("does not mutate the command table it is handed", function()
    -- The lazy stub passes nvim's own table straight through.
    local cmd = { fargs = { "close" } }
    commands.dispatch(cmd)
    assert.same({ "close" }, cmd.fargs)
  end)

  it("registers the user command", function()
    commands.setup()
    assert.is_table(vim.api.nvim_get_commands({})["GitVim"])
  end)
end)
