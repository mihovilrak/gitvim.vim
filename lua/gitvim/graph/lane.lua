--- Lane assignment for the commit graph. PURE: no nvim API, no git.
---
--- Commits arrive newest first (`git log --date-order`). The layout keeps an
--- ordered array of active lanes, each waiting for the SHA it will draw next.
--- Per commit it:
---
---   1. finds the lane waiting for the commit, or allocates one (a branch tip
---      or an orphan root);
---   2. closes every *other* lane waiting for it -- branches converging on
---      their fork point -- with `╯`;
---   3. hands the node's lane to the first parent, and joins each further
---      parent to a lane already waiting for it (`├` / `┤`), or opens a new
---      lane for it (`╮` / `╭`).
---
--- Each lane gets a color id when it is allocated and keeps it until it
--- closes, so a branch is one color from its tip to its fork point. The
--- renderer maps ids onto the highlight palette.
---
--- A layout is incremental: `push` one commit at a time, and the next page of
--- `git log` continues the same lanes where the previous one stopped.
---
--- Output cells are two display columns per lane: the lane glyph and the gap
--- to its right, which a horizontal connector fills with `─`.

local M = {}

M.NODE = "●"
M.PASS = "│"
M.HORIZONTAL = "─"
M.CROSS = "┼"
--- Another lane converging on this row's node, from the right.
M.CLOSE = "╯"
--- A merge parent getting a fresh lane to the right / to the left.
M.OPEN_RIGHT = "╮"
M.OPEN_LEFT = "╭"
--- A merge parent joining a lane that is already waiting for it.
M.JOIN_RIGHT = "┤"
M.JOIN_LEFT = "├"
--- A connector glyph that a horizontal line also runs through.
M.TEE_DOWN = "┬"
M.TEE_UP = "┴"

---@class gitvim.lane.Commit
---@field sha string
---@field parents string[]

---@class gitvim.lane.Cell
---@field text string   one display column
---@field color? integer  lane color id; nil for blank cells

---@class gitvim.lane.Row
---@field sha string
---@field lane integer             1-based lane of the node
---@field color integer            the node's color id
---@field cells gitvim.lane.Cell[] the node row, two cells per lane
---@field next gitvim.lane.Cell[]  the lanes after this row, for rows drawn
---                                beneath the commit (its expanded files)

---@class gitvim.lane.Slot
---@field sha string
---@field color integer

---@class gitvim.lane.Layout
---@field lanes (gitvim.lane.Slot|false)[]  `false` is a free slot
---@field colors integer                     the last color id handed out
local Layout = {}
Layout.__index = Layout

---@return gitvim.lane.Layout
function M.new()
  return setmetatable({ lanes = {}, colors = 0 }, Layout)
end

---@private
---@return integer
function Layout:color()
  self.colors = self.colors + 1
  return self.colors
end

--- The first free slot, or a new one on the right.
---@private
---@return integer
function Layout:free()
  for i, slot in ipairs(self.lanes) do
    if not slot then
      return i
    end
  end
  return #self.lanes + 1
end

---@private
function Layout:trim()
  while #self.lanes > 0 and not self.lanes[#self.lanes] do
    self.lanes[#self.lanes] = nil
  end
end

--- Pass-through cells for the current lanes.
---@private
---@param n integer  number of lanes to draw
---@return gitvim.lane.Cell[]
function Layout:passthrough(n)
  local cells = {}
  for i = 1, n do
    local slot = self.lanes[i]
    if slot then
      cells[#cells + 1] = { text = M.PASS, color = slot.color }
    else
      cells[#cells + 1] = { text = " " }
    end
    cells[#cells + 1] = { text = " " }
  end
  return cells
end

--- Draw a horizontal connector from the node at `from` to lane `to`.
---@param cells gitvim.lane.Cell[]
---@param from integer
---@param to integer
---@param color integer
local function connect(cells, from, to, color)
  local lo, hi = math.min(from, to), math.max(from, to)
  for i = lo, hi - 1 do
    -- The gap to the right of lane i.
    local gap = cells[2 * i]
    if gap.text == " " then
      cells[2 * i] = { text = M.HORIZONTAL, color = color }
    end
    if i > lo then
      local cell = cells[2 * i - 1]
      if cell.text == M.PASS then
        cells[2 * i - 1] = { text = M.CROSS, color = cell.color }
      elseif cell.text == " " then
        cells[2 * i - 1] = { text = M.HORIZONTAL, color = color }
      elseif cell.text == M.OPEN_RIGHT or cell.text == M.OPEN_LEFT then
        cells[2 * i - 1] = { text = M.TEE_DOWN, color = cell.color }
      elseif cell.text == M.CLOSE then
        cells[2 * i - 1] = { text = M.TEE_UP, color = cell.color }
      end
    end
  end
end

--- Put a connector glyph at lane `lane`. Where a longer horizontal line
--- already runs through the cell the glyph becomes a tee, so an octopus
--- merge reads `●─┬─╮` rather than `●─╮─╮`.
---@param cells gitvim.lane.Cell[]
---@param lane integer
---@param glyph string
---@param color integer
local function put(cells, lane, glyph, color)
  local existing = cells[2 * lane - 1].text
  if existing == M.HORIZONTAL or existing == M.CROSS then
    if glyph == M.OPEN_RIGHT or glyph == M.OPEN_LEFT then
      glyph = M.TEE_DOWN
    elseif glyph == M.CLOSE then
      glyph = M.TEE_UP
    else
      glyph = M.CROSS
    end
  end
  cells[2 * lane - 1] = { text = glyph, color = color }
end

--- Lay out one commit and advance the lanes past it.
---@param commit gitvim.lane.Commit
---@return gitvim.lane.Row
function Layout:push(commit)
  local lanes = self.lanes

  -- 1. The lane waiting for this commit, or a new one.
  local idx
  for i, slot in ipairs(lanes) do
    if slot and slot.sha == commit.sha then
      idx = i
      break
    end
  end
  if not idx then
    idx = self:free()
    lanes[idx] = { sha = commit.sha, color = self:color() }
  end
  local node = lanes[idx] --[[@as gitvim.lane.Slot]]

  -- 2. Every other lane waiting for it converges here. The first match is
  -- the leftmost, so they are all to the right of the node.
  local closing = {}
  for i = idx + 1, #lanes do
    local slot = lanes[i]
    if slot and slot.sha == commit.sha then
      closing[#closing + 1] = { lane = i, color = slot.color }
    end
  end

  -- 3. Parents. The first keeps the node's lane (and color); the rest join
  -- a lane already waiting for them or open one. A lane closing on this row
  -- is still occupied, so a `╯` and a `╮` never share a cell.
  local closed = {}
  for _, c in ipairs(closing) do
    closed[c.lane] = true
  end

  local width = #lanes
  local joins = {}
  local seen = { [commit.parents[1] or ""] = true }
  for p = 2, #commit.parents do
    local parent = commit.parents[p]
    if not seen[parent] then
      seen[parent] = true
      local target
      for i, slot in ipairs(lanes) do
        if i ~= idx and not closed[i] and slot and slot.sha == parent then
          target = i
          break
        end
      end
      if target then
        joins[#joins + 1] = { lane = target, color = lanes[target].color, open = false }
      else
        target = self:free()
        lanes[target] = { sha = parent, color = self:color() }
        joins[#joins + 1] = { lane = target, color = lanes[target].color, open = true }
      end
    end
  end
  width = math.max(width, #lanes)

  -- Draw: lanes as they stood, the node, then the connectors. Freshly
  -- opened lanes do not exist above this row, so they start blank.
  local cells = {}
  for i = 1, width do
    local slot = lanes[i]
    local fresh = false
    for _, j in ipairs(joins) do
      fresh = fresh or (j.open and j.lane == i)
    end
    if slot and not fresh then
      cells[#cells + 1] = { text = M.PASS, color = slot.color }
    else
      cells[#cells + 1] = { text = " " }
    end
    cells[#cells + 1] = { text = " " }
  end
  cells[2 * idx - 1] = { text = M.NODE, color = node.color }

  for _, c in ipairs(closing) do
    connect(cells, idx, c.lane, c.color)
    put(cells, c.lane, M.CLOSE, c.color)
  end
  for _, j in ipairs(joins) do
    connect(cells, idx, j.lane, j.color)
    local glyph
    if j.open then
      glyph = j.lane > idx and M.OPEN_RIGHT or M.OPEN_LEFT
    else
      glyph = j.lane > idx and M.JOIN_RIGHT or M.JOIN_LEFT
    end
    put(cells, j.lane, glyph, j.color)
  end

  -- Advance: converged lanes free up, the node's lane follows its first
  -- parent or ends at a root.
  for _, c in ipairs(closing) do
    lanes[c.lane] = false
  end
  if commit.parents[1] then
    node.sha = commit.parents[1]
  else
    lanes[idx] = false
  end
  self:trim()

  -- The trailing gap after the last lane is never drawn.
  while #cells > 0 and cells[#cells].text == " " do
    cells[#cells] = nil
  end
  local next = self:passthrough(#lanes)
  while #next > 0 and next[#next].text == " " do
    next[#next] = nil
  end

  return { sha = commit.sha, lane = idx, color = node.color, cells = cells, next = next }
end

--- Lanes still waiting for a commit: what a further page would continue.
---@return string[]
function Layout:pending()
  local out = {}
  for _, slot in ipairs(self.lanes) do
    if slot then
      out[#out + 1] = slot.sha
    end
  end
  return out
end

--- Lay out a whole list of commits at once.
---@param commits gitvim.lane.Commit[]
---@return gitvim.lane.Row[]
---@return gitvim.lane.Layout
function M.layout(commits)
  local layout = M.new()
  local rows = {}
  for i, commit in ipairs(commits) do
    rows[i] = layout:push(commit)
  end
  return rows, layout
end

--- The cells as plain text, for tests and for measuring.
---@param cells gitvim.lane.Cell[]
---@return string
function M.text(cells)
  local out = {}
  for i, cell in ipairs(cells) do
    out[i] = cell.text
  end
  return table.concat(out)
end

return M
