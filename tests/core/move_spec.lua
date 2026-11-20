local h = require('tests.helpers')
local ids = h.ids

describe('move()', function()
  local backend = require('smart-splits-backend-rex')

  before_each(function()
    h.cursor('top')
  end)

  after_each(function()
    h.restore()
  end)

  ---@param rex table the fake from `h.rex`
  ---@return string[] the block ids focused, in order
  local function focused(rex)
    return vim.tbl_map(function(c)
      return c.args.block_id
    end, rex.sent('focus_block'))
  end

  it('sends what only Neovim knows', function()
    local rex = h.rex('nested-4pane', ids.A)
    backend.move('right', { at_edge = 'wrap' })
    local req = rex.requests[1]
    assert.are.same({ 'move', 'right', ids.A, 'wrap' }, { req.op, req.dir, req.block, req.at_edge })
    assert.are.same({ vim.o.lines, vim.o.columns, 0, 0 }, { req.rows, req.cols, req.row, req.col })
    assert.is_false(req.disable_nav_when_zoomed)
    assert.is_nil(req.cwd)
  end)

  it('focuses the only pane across the edge', function()
    local rex = h.rex('nested-4pane', ids.A)
    assert.is_true(backend.move('right', {}))
    assert.is_true(backend.move('down', {}))
    assert.are.same({ ids.B, ids.D }, focused(rex))
    assert.are.equal(2, #rex.calls)
  end)

  it('of several panes across the edge, focuses the one level with the cursor', function()
    local rex = h.rex('nested-4pane', ids.B)
    h.cursor('top')
    assert.is_true(backend.move('left', {}))
    h.cursor('bottom')
    assert.is_true(backend.move('left', {}))
    vim.env.REX_BLOCK = ids.D
    h.cursor('top')
    assert.is_true(backend.move('right', {}))
    h.cursor('bottom')
    assert.is_true(backend.move('right', {}))
    assert.are.same({ ids.A, ids.D, ids.B, ids.C }, focused(rex))
  end)

  it('across a top or bottom edge, goes by the cursor column', function()
    -- nested-4pane on its side: A and D side by side on top, B and C below
    local rex = h.rex(h.transposed('nested-4pane'), ids.B)
    h.cursor('left')
    assert.is_true(backend.move('up', {}))
    h.cursor('right')
    assert.is_true(backend.move('up', {}))
    vim.env.REX_BLOCK = ids.D
    h.cursor('left')
    assert.is_true(backend.move('down', {}))
    h.cursor('right')
    assert.is_true(backend.move('down', {}))
    assert.are.same({ ids.A, ids.D, ids.B, ids.C }, focused(rex))
  end)

  it('without a cursor position, focuses the pane sharing most of the edge', function()
    local layout = require('smart-splits-backend-rex.layout')
    local view = h.fixture('nested-4pane')
    -- D's right edge: B shares 0.3 of it, C 0.4
    assert.are.same({ 'focus_block', { block_id = ids.C } }, {
      layout.plan(view, { op = 'move', dir = 'right', block = ids.D }),
    })
  end)

  it('is not handled at the edge with at_edge stop or unset', function()
    local rex = h.rex('nested-4pane', ids.A)
    assert.is_false(backend.move('left', { at_edge = 'stop' }))
    assert.is_false(backend.move('up', {}))
    assert.is_false(backend.move('left'))
    assert.are.same({}, rex.calls)
  end)

  describe("with at_edge 'wrap'", function()
    it('focuses the farthest pane level with me on the other side', function()
      local rex = h.rex('nested-4pane', ids.A)
      assert.is_true(backend.move('left', { at_edge = 'wrap' }))
      assert.is_true(backend.move('up', { at_edge = 'wrap' }))
      vim.env.REX_BLOCK = ids.C
      assert.is_true(backend.move('down', { at_edge = 'wrap' }))
      assert.are.same({ ids.B, ids.D, ids.B }, focused(rex))
    end)

    it('lets the cursor choose between equally far panes', function()
      local rex = h.rex('nested-4pane', ids.B)
      h.cursor('top')
      assert.is_true(backend.move('right', { at_edge = 'wrap' }))
      h.cursor('bottom')
      assert.is_true(backend.move('right', { at_edge = 'wrap' }))
      assert.are.same({ ids.A, ids.D }, focused(rex))
    end)

    it('is not handled when no pane is level with me', function()
      local rex = h.rex('single-pane', ids.A)
      for _, dir in ipairs({ 'left', 'right', 'up', 'down' }) do
        assert.is_false(backend.move(dir, { at_edge = 'wrap' }))
      end
      assert.are.same({}, rex.calls)
    end)
  end)

  describe("with at_edge 'split'", function()
    it('splits a new shell off my pane on that side, focused, in my directory', function()
      local rex = h.rex('single-pane', ids.A)
      local want = {
        left = { 'horizontal', 'before' },
        right = { 'horizontal', 'after' },
        up = { 'vertical', 'before' },
        down = { 'vertical', 'after' },
      }
      for dir, how in pairs(want) do
        rex.calls = {}
        assert.is_true(backend.move(dir, { at_edge = 'split' }))
        assert.are.same({
          method = 'new_split',
          args = {
            anchor_id = ids.A,
            direction = how[1],
            side = how[2],
            focus = true,
            layout = { block = { flavor = 'com.superlogical.terminal.shell', options = { cwd = vim.fn.getcwd() } } },
          },
        }, rex.calls[1])
      end
    end)

    it("in this window's directory when it has its own", function()
      local rex = h.rex('single-pane', ids.A)
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      vim.cmd.lcd(dir)
      backend.move('right', { at_edge = 'split' })
      vim.cmd.lcd(vim.fn.getcwd(-1, -1))
      assert.are.equal(vim.uv.fs_realpath(dir), vim.uv.fs_realpath(rex.calls[1].args.layout.block.options.cwd))
    end)

    it('sends no options without a directory, never an empty JSON array', function()
      local layout = require('smart-splits-backend-rex.layout')
      local method, args =
        layout.plan(h.fixture('single-pane'), { op = 'move', dir = 'right', block = ids.A, at_edge = 'split' })
      assert.are.equal('new_split', method)
      assert.are.same({ flavor = 'com.superlogical.terminal.shell' }, args.layout.block)
      assert.is_nil(vim.json.encode(args):find('"options"'))
    end)

    it('still moves when there is a pane that way', function()
      local rex = h.rex('nested-4pane', ids.A)
      assert.is_true(backend.move('right', { at_edge = 'split' }))
      assert.are.same({ ids.B }, focused(rex))
      assert.are.same({}, rex.sent('new_split'))
    end)
  end)

  describe('in a zoomed tab', function()
    it('moves anyway by default, as Rex does', function()
      local rex = h.rex('nested-4pane-zoomed-B', ids.B)
      assert.is_true(backend.move('down', {}))
      assert.are.same({ ids.C }, focused(rex))
    end)

    it('is not handled with disable_nav_when_zoomed', function()
      backend.setup({ disable_nav_when_zoomed = true })
      local rex = h.rex('nested-4pane-zoomed-B', ids.B)
      assert.is_false(backend.move('down', {}))
      assert.is_false(backend.move('right', { at_edge = 'split' }))
      assert.are.same({}, rex.calls)
    end)

    it('disable_nav_when_zoomed leaves an unzoomed tab alone', function()
      backend.setup({ disable_nav_when_zoomed = true })
      local rex = h.rex('nested-4pane', ids.B)
      assert.is_true(backend.move('down', {}))
      assert.are.same({ ids.C }, focused(rex))
    end)
  end)

  it('keeps a floating pane and the tiled panes under it apart', function()
    local rex = h.rex('nested-4pane-plus-floating', ids.A)
    -- F floats over the middle of the tab, but in its own layer
    assert.is_true(backend.move('right', {}))
    assert.is_true(backend.move('down', {}))
    vim.env.REX_BLOCK = ids.F
    for _, dir in ipairs({ 'left', 'right', 'up', 'down' }) do
      assert.is_false(backend.move(dir, { at_edge = 'wrap' }))
    end
    assert.are.same({ ids.B, ids.D }, focused(rex))
  end)

  it('finds my pane in a tab other than the active one', function()
    local rex = h.rex('nested-4pane-plus-floating', ids.E)
    assert.is_false(backend.move('left', { at_edge = 'wrap' }))
    assert.is_true(backend.move('left', { at_edge = 'split' }))
    assert.are.equal(ids.E, rex.calls[1].args.anchor_id)
  end)

  it('is not handled when Rex does not know my pane', function()
    local rex = h.rex('nested-4pane', 'block:01a1f774-0000-7000-8000-000000000000')
    assert.is_false(backend.move('right', { at_edge = 'split' }))
    assert.are.equal(1, #rex.requests)
    assert.are.same({}, rex.calls)
  end)

  it('is not handled when Rex refuses the focus', function()
    h.rex('nested-4pane', ids.A, { call_error = 'not_found: block is not in any window' })
    assert.is_false(backend.move('right', {}))
  end)
end)
