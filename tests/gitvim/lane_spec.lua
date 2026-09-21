--- The pure lane engine: topologies drawn as text, plus invariants.

local lane = require("gitvim.graph.lane")

---@param spec { [1]: string, [2]: string[] }[]  { sha, parents }
---@return gitvim.lane.Commit[]
local function commits(spec)
  local out = {}
  for i, c in ipairs(spec) do
    out[i] = { sha = c[1], parents = c[2] }
  end
  return out
end

---@param list gitvim.lane.Commit[]
---@return string[]
local function picture(list)
  local rows = lane.layout(list)
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = lane.text(row.cells)
  end
  return out
end

--- Every commit gets exactly one node, in the lane the engine reports, and
--- every lane is closed once the last root has been drawn.
---@param list gitvim.lane.Commit[]
local function assert_sound(list)
  local rows, layout = lane.layout(list)
  assert.equals(#list, #rows)
  for i, row in ipairs(rows) do
    local nodes = 0
    for _, cell in ipairs(row.cells) do
      if cell.text == lane.NODE then
        nodes = nodes + 1
      end
    end
    assert.equals(1, nodes, "one node on row " .. i)
    assert.equals(lane.NODE, row.cells[2 * row.lane - 1].text)
    assert.equals(list[i].sha, row.sha)
  end
  assert.same({}, layout:pending())
end

describe("graph lanes", function()
  it("keeps a linear history in one lane", function()
    local list = commits({ { "c", { "b" } }, { "b", { "a" } }, { "a", {} } })
    assert.same({ "●", "●", "●" }, picture(list))
    local rows = lane.layout(list)
    assert.equals(rows[1].color, rows[3].color)
    assert_sound(list)
  end)

  it("forks a lane for a merge and closes it at the fork point", function()
    local list = commits({
      { "merge", { "fix", "feat" } },
      { "fix", { "base" } },
      { "feat", { "base" } },
      { "base", { "init" } },
      { "init", {} },
    })
    assert.same({ "●─╮", "● │", "│ ●", "●─╯", "●" }, picture(list))

    local rows = lane.layout(list)
    -- The branch keeps its own color from the fork to the merge.
    assert.equals(rows[1].cells[3].color, rows[3].color)
    assert.are_not.equal(rows[1].color, rows[3].color)
    -- The rows under the merge (its expanded files) continue both lanes.
    assert.equals("│ │", lane.text(rows[1].next))
    assert_sound(list)
  end)

  it("draws two branch tips converging without a merge", function()
    local list = commits({
      { "a2", { "base" } },
      { "b2", { "base" } },
      { "base", {} },
    })
    assert.same({ "●", "│ ●", "●─╯" }, picture(list))
    assert_sound(list)
  end)

  it("lays out an octopus merge", function()
    local list = commits({
      { "m", { "a", "b", "c" } },
      { "a", { "r" } },
      { "b", { "r" } },
      { "c", { "r" } },
      { "r", {} },
    })
    assert.same(
      { "●─┬─╮", "● │ │", "│ ● │", "│ │ ●", "●─┴─╯" },
      picture(list)
    )
    assert_sound(list)
  end)

  it("gives an orphan root its own lane and frees it", function()
    local list = commits({
      { "d2", { "d1" } },
      { "m1", { "m0" } },
      { "d1", {} },
      { "m0", {} },
      -- A later tip reuses the freed slot rather than widening the graph.
    })
    assert.same({ "●", "│ ●", "● │", "  ●" }, picture(list))
    assert_sound(list)

    local layout = lane.new()
    for _, c in ipairs(commits({ { "x", {} } })) do
      layout:push(c)
    end
    local row = layout:push({ sha = "y", parents = {} })
    assert.equals(1, row.lane)
  end)

  it("handles a criss-cross merge", function()
    --   m = merge(a2, b2); a2 = merge(a1, b1); b2 = merge(b1, a1)
    local list = commits({
      { "m", { "a2", "b2" } },
      { "b2", { "b1", "a1" } },
      { "a2", { "a1", "b1" } },
      { "b1", { "base" } },
      { "a1", { "base" } },
      { "base", {} },
    })
    assert_sound(list)
    -- b2 opens a lane for a1; a2 keeps its lane for a1 and joins b1's. The
    -- two lanes waiting for a1 converge on it, crossing b1's lane.
    assert.same({
      "●─╮",
      "│ ●─╮",
      "●─┤ │",
      "│ ● │",
      "●─┼─╯",
      "●─╯",
    }, picture(list))
  end)

  it("joins a merge parent to an existing lane on its left", function()
    local list = commits({
      { "t1", { "p" } },
      { "t2", { "q", "p" } },
      { "q", { "p" } },
      { "p", {} },
    })
    assert.same({ "●", "├─●", "│ ●", "●─╯" }, picture(list))
    assert_sound(list)
  end)

  it("continues the same lanes across pages", function()
    local list = commits({
      { "merge", { "fix", "feat" } },
      { "fix", { "base" } },
      { "feat", { "base" } },
      { "base", {} },
    })
    local whole = picture(list)

    local layout = lane.new()
    local paged = {}
    for i, c in ipairs(list) do
      paged[i] = lane.text(layout:push(c).cells)
      if i == 2 then
        assert.same({ "base", "feat" }, layout:pending())
      end
    end
    assert.same(whole, paged)
  end)
end)
