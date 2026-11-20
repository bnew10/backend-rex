local h = require('tests.helpers')
local ids = h.ids

describe('resize()', function()
  local backend = require('smart-splits-backend-rex')

  after_each(function()
    h.restore()
  end)

  ---The one `resize_pane` call made, with its ratio checked to 1e-9 and removed.
  ---@param rex table the fake from `h.rex`
  ---@param ratio number
  local function resized(rex, ratio)
    assert.are.equal(1, #rex.calls)
    local call = rex.calls[1]
    assert.are.equal('resize_pane', call.method)
    assert.is_true(math.abs(call.args.ratio - ratio) < 1e-9, ('ratio %.12f, want %.12f'):format(call.args.ratio, ratio))
    call.args.ratio = nil
    return call.args
  end

  -- In nested-4pane A is half the window wide, so the outer split is twice A's
  -- columns, and A is 0.3 of the left split's height, so that split is
  -- rows / 0.3 tall. A border that moves `amount` of those cells moves
  -- amount / (split cells) in ratio.
  local cols, rows

  before_each(function()
    cols, rows = vim.o.columns, vim.o.lines
  end)

  it("never takes one axis's size for the other's", function()
    local layout = require('smart-splits-backend-rex.layout')
    local view = h.fixture('nested-4pane')
    for dir, req in pairs({ right = { rows = 40 }, down = { cols = 100 } }) do
      req.op, req.dir, req.block = 'resize', dir, ids.A
      assert.are.same({ nil, 'bad request' }, { layout.plan(view, req) })
    end
  end)

  it('sends the amount and the pane size in cells', function()
    local rex = h.rex('nested-4pane', ids.A)
    backend.resize('right', { amount = 7 })
    local req = rex.requests[1]
    assert.are.same(
      { 'resize', 'right', ids.A, 7, cols, rows },
      { req.op, req.dir, req.block, req.amount, req.cols, req.rows }
    )
  end)

  it('right and down move my right or bottom border out', function()
    local rex = h.rex('nested-4pane', ids.A)
    assert.is_true(backend.resize('right', { amount = 3 }))
    assert.are.same(
      { direction = 'horizontal', before_block_id = ids.A, after_block_id = ids.B },
      resized(rex, 0.5 + 3 / (cols * 2))
    )
    rex.calls = {}
    assert.is_true(backend.resize('down', { amount = 3 }))
    assert.are.same(
      { direction = 'vertical', before_block_id = ids.A, after_block_id = ids.D },
      resized(rex, 0.3 + 3 / (rows / 0.3))
    )
  end)

  it('left and up move that border back', function()
    local rex = h.rex('nested-4pane', ids.A)
    assert.is_true(backend.resize('left', { amount = 3 }))
    resized(rex, 0.5 - 3 / (cols * 2))
    rex.calls = {}
    assert.is_true(backend.resize('up', { amount = 3 }))
    resized(rex, 0.3 - 3 / (rows / 0.3))
  end)

  it('with no border after my pane, moves the one before it, in the key direction', function()
    local rex = h.rex('nested-4pane', ids.C)
    -- C is the right column's bottom pane: its only borders are its left and top
    assert.is_true(backend.resize('left', { amount = 2 }))
    assert.are.same(
      { direction = 'horizontal', before_block_id = ids.A, after_block_id = ids.C },
      resized(rex, 0.5 - 2 / (cols * 2))
    )
    rex.calls = {}
    assert.is_true(backend.resize('down', { amount = 2 }))
    assert.are.same(
      { direction = 'vertical', before_block_id = ids.B, after_block_id = ids.C },
      resized(rex, 0.6 + 2 / (rows / 0.4))
    )
  end)

  it('resizes by 3 cells when core names no amount', function()
    local rex = h.rex('nested-4pane', ids.A)
    assert.is_true(backend.resize('right'))
    resized(rex, 0.5 + 3 / (cols * 2))
  end)

  it('clamps the ratio to 0.05..0.95', function()
    local rex = h.rex('nested-4pane', ids.A)
    assert.is_true(backend.resize('right', { amount = 10000 }))
    resized(rex, 0.95)
    rex.calls = {}
    assert.is_true(backend.resize('up', { amount = 10000 }))
    resized(rex, 0.05)
  end)

  it('is not handled at the clamp, and the clamp never moves a border backwards', function()
    local view = h.fixture('nested-4pane')
    local outer = view.windows[1].layers[1].layout.split
    outer.ratio = 0.95
    local rex = h.rex(view, ids.A)
    assert.is_false(backend.resize('right', { amount = 3 }))
    -- dragged past the clamp by something else
    outer.ratio = 0.999
    assert.is_false(backend.resize('right', { amount = 3 }))
    assert.are.same({}, rex.calls)
    assert.is_true(backend.resize('left', { amount = 3 }))
    resized(rex, 0.95)
  end)

  it('is not handled without a border on that axis', function()
    local rex = h.rex('single-pane', ids.A)
    for _, dir in ipairs({ 'left', 'right', 'up', 'down' }) do
      assert.is_false(backend.resize(dir, { amount = 3 }))
    end
    vim.env.REX_BLOCK = ids.F
    rex.view = h.fixture('nested-4pane-plus-floating')
    assert.is_false(backend.resize('right', { amount = 3 }))
    assert.are.same({}, rex.calls)
  end)

  it('is never handled in a zoomed tab', function()
    local rex = h.rex('nested-4pane-zoomed-B', ids.B)
    for _, dir in ipairs({ 'left', 'right', 'up', 'down' }) do
      assert.is_false(backend.resize(dir, { amount = 3 }))
    end
    assert.are.same({}, rex.calls)
  end)

  it('is not handled when Rex does not know my pane', function()
    local rex = h.rex('nested-4pane', 'block:01a1f774-0000-7000-8000-000000000000')
    assert.is_false(backend.resize('right', { amount = 3 }))
    assert.are.same({}, rex.calls)
  end)
end)
