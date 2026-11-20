---The Rex side of the backend. Plain Lua 5.1 with no `vim`: Neovim runs it in
---the `rex` CLI's interpreter, one process per keypress,
---
---    rex do -s SESSION -e 'return dofile(<this file>).handle(rex, rex.args)' --args REQUEST
---
---and a Rex config can `dofile` it too (see the README). Everything but
---`handle` is a pure function of a `session.view` snapshot: a layout node is
---`{ rect, block_id }` or `{ rect, split = { direction, ratio, before, after } }`,
---a rect is `{ x, y, w, h }` in fractions of the window, `horizontal` puts
---`before` on the left, `vertical` puts it on top, and `ratio` is `before`'s share.

local M = {}

-- rects are fractions computed by the server, so edges meet up to rounding
local EPS = 1e-6
-- the server accepts 0.999, which leaves a pane one cell wide or none
local MIN_RATIO, MAX_RATIO = 0.05, 0.95
-- cells, when the request names no amount: smart-splits' own default
local AMOUNT = 3
local SHELL = 'com.superlogical.terminal.shell'

local AXIS = { left = 'horizontal', right = 'horizontal', up = 'vertical', down = 'vertical' }
local OPPOSITE = { left = 'right', right = 'left', up = 'down', down = 'up' }
-- towards a split's `after` side
local FORWARD = { right = true, down = true }

---The coordinate of `r`'s side facing `dir`.
local function side(r, dir)
  if dir == 'left' then
    return r[1]
  elseif dir == 'right' then
    return r[1] + r[3]
  elseif dir == 'up' then
    return r[2]
  end
  return r[2] + r[4]
end

---`r`'s extent across the direction of travel: its rows for left/right, its
---columns for up/down.
local function span(r, dir)
  if AXIS[dir] == 'horizontal' then
    return r[2], r[2] + r[4]
  end
  return r[1], r[1] + r[3]
end

local function overlap(a, b, dir)
  local a0, a1 = span(a, dir)
  local b0, b1 = span(b, dir)
  return math.min(a1, b1) - math.max(a0, b0)
end

local function leaves(node, out)
  if node.block_id then
    out[#out + 1] = { id = node.block_id, rect = node.rect }
  elseif node.split then
    leaves(node.split.before, out)
    leaves(node.split.after, out)
  end
  return out
end

local function first_leaf(node)
  while node.split do
    node = node.split.before
  end
  return node.block_id
end

---The window and layer whose layout holds `block`, that layer's leaves, and
---`block`'s own leaf. Floating layers count: a pane there navigates among the
---panes of its own layer.
function M.locate(view, block)
  for _, window in ipairs(view.windows or {}) do
    for _, layer in ipairs(window.layers or {}) do
      if layer.layout then
        local all = leaves(layer.layout, {})
        for _, leaf in ipairs(all) do
          if leaf.id == block then
            return { window = window, layer = layer, leaves = all, me = leaf }
          end
        end
      end
    end
  end
  return nil
end

---Where the Neovim cursor sits along the edge being crossed, in window
---fractions, from its cell in the pane. `nil` when the request does not say.
local function cursor(me, dir, req)
  local cell, cells = req.row, req.rows
  if AXIS[dir] == 'vertical' then
    cell, cells = req.col, req.cols
  end
  if type(cell) ~= 'number' or type(cells) ~= 'number' or cells <= 0 then
    return nil
  end
  local lo, hi = span(me.rect, dir)
  return lo + (cell + 0.5) / cells * (hi - lo)
end

---Of the leaves a move could land on, the one level with the cursor, else the
---one sharing the most of my edge.
local function choose(candidates, me, dir, at)
  local best, most
  for _, c in ipairs(candidates) do
    local lo, hi = span(c.rect, dir)
    if at and lo <= at and at < hi then
      return c.id
    end
    local shared = overlap(me.rect, c.rect, dir)
    if not most or shared > most + EPS then
      best, most = c.id, shared
    end
  end
  return best
end

---The leaf across my edge in `dir`, or `nil` at the edge of the layer.
function M.neighbour(where, dir, at)
  local me, candidates = where.me, {}
  for _, c in ipairs(where.leaves) do
    if
      c.id ~= me.id
      and math.abs(side(c.rect, OPPOSITE[dir]) - side(me.rect, dir)) < EPS
      and overlap(me.rect, c.rect, dir) > EPS
    then
      candidates[#candidates + 1] = c
    end
  end
  return choose(candidates, me, dir, at)
end

---Where a wrap past my edge in `dir` lands: of the leaves level with me, the
---farthest the other way. `nil` when no other leaf is level with me.
function M.farthest(where, dir, at)
  local back = OPPOSITE[dir]
  local sign = FORWARD[back] and 1 or -1
  local me, candidates, far = where.me, {}, nil
  for _, c in ipairs(where.leaves) do
    if c.id ~= me.id and overlap(me.rect, c.rect, dir) > EPS then
      local reach = side(c.rect, back) * sign
      if not far or reach > far + EPS then
        candidates, far = { c }, reach
      elseif reach > far - EPS then
        candidates[#candidates + 1] = c
      end
    end
  end
  return choose(candidates, me, dir, at)
end

---The split whose border a resize along `axis` moves, as tmux `resize-pane`
---picks it: the nearest ancestor on that axis with `block` on its before side
---(my right or bottom border), else the nearest with `block` on its after side.
---`ids` holds one leaf from each side, which is how `session.resize_pane` names
---a split.
function M.border(layout, block, axis)
  local before, after
  local function walk(node)
    if node.block_id then
      return node.block_id == block
    end
    local split = node.split
    if not split then
      return false
    end
    if walk(split.before) then
      if split.direction == axis and not before then
        before = { node = node, ids = { block, first_leaf(split.after) } }
      end
      return true
    end
    if walk(split.after) then
      if split.direction == axis and not after then
        after = { node = node, ids = { first_leaf(split.before), block } }
      end
      return true
    end
    return false
  end
  walk(layout)
  return before or after
end

---The new ratio for a resize by `amount` cells: `cells` are my pane's cells on
---that axis, scaled up from my extent to the split's, so the border moves by
---`amount` of them. Clamped, and never moved against `dir` by the clamp: `nil`
---when the border cannot move that way.
local function ratio(split_node, me, axis, dir, amount, cells)
  local k = axis == 'horizontal' and 3 or 4
  local delta = amount / (cells * split_node.rect[k] / me.rect[k])
  local sign = FORWARD[dir] and 1 or -1
  local from = split_node.split.ratio
  local to = math.max(MIN_RATIO, math.min(MAX_RATIO, from + sign * delta))
  if (to - from) * sign <= EPS then
    return nil
  end
  return to
end

---What to ask Rex for, as `method, args`, or `nil, why` when the request is
---not one this layout can handle.
---@param view table a `session.view` result
---@param req table `{ op = 'move'|'resize', dir, block, ... }`, see init.lua
---@return string|nil method a `rex.session` method
---@return table|string args its arguments, or why there is nothing to do
function M.plan(view, req)
  local dir = req.dir
  if not AXIS[dir] or type(req.block) ~= 'string' then
    return nil, 'bad request'
  end
  local where = M.locate(view, req.block)
  if not where then
    return nil, 'block not in this session'
  end
  local zoomed = where.window.zoomed_block_id ~= nil

  if req.op == 'move' then
    if zoomed and req.disable_nav_when_zoomed then
      return nil, 'zoomed'
    end
    local at = cursor(where.me, dir, req)
    local target = M.neighbour(where, dir, at)
    if not target and req.at_edge == 'wrap' then
      target = M.farthest(where, dir, at)
    end
    if target then
      return 'focus_block', { block_id = target }
    end
    if req.at_edge == 'split' then
      return 'new_split',
        {
          anchor_id = req.block,
          direction = AXIS[dir],
          side = FORWARD[dir] and 'after' or 'before',
          focus = true,
          layout = { block = { flavor = SHELL, options = { cwd = req.cwd } } },
        }
    end
    return nil, 'edge'
  end

  if req.op == 'resize' then
    -- the border would move under a pane drawn over the whole window
    if zoomed then
      return nil, 'zoomed'
    end
    local axis = AXIS[dir]
    local amount, cells = req.amount or AMOUNT, axis == 'horizontal' and req.cols or req.rows
    if type(amount) ~= 'number' or type(cells) ~= 'number' or cells <= 0 then
      return nil, 'bad request'
    end
    local border = M.border(where.layer.layout, req.block, axis)
    if not border then
      return nil, 'no border'
    end
    local to = ratio(border.node, where.me, axis, dir, amount, cells)
    if not to then
      return nil, 'at limit'
    end
    return 'resize_pane',
      { direction = axis, before_block_id = border.ids[1], after_block_id = border.ids[2], ratio = to }
  end

  return nil, 'bad request'
end

---One request in, one reply out: read the layout, decide, act, all in the one
---process. `rex` is the API table a Rex script or config is given. Never
---raises for anything Rex reports; the reply says why nothing happened.
---@param rex table
---@param req table
---@return { handled: boolean, did?: string, args?: table, why?: string }
function M.handle(rex, req)
  local view, err = rex.session.view({})
  if not view then
    return { handled = false, why = tostring(err) }
  end

  if req.op == 'locate' then
    local where = type(req.block) == 'string' and M.locate(view, req.block)
    if not where then
      return { handled = false, why = 'block not in this session' }
    end
    return {
      handled = true,
      window = where.window.label or where.window.window_id,
      layer = where.layer.kind,
      panes = #where.leaves,
      zoomed = where.window.zoomed_block_id ~= nil,
    }
  end

  local method, args = M.plan(view, req)
  if not method then
    return { handled = false, why = args }
  end
  local _, call_err = rex.session[method](args)
  if call_err ~= nil then
    return { handled = false, why = tostring(call_err) }
  end
  return { handled = true, did = method, args = args }
end

return M
