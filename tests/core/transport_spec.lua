local h = require('tests.helpers')
local ids = h.ids

describe('the Neovim-to-rex boundary', function()
  local backend = require('smart-splits-backend-rex')

  after_each(function()
    h.restore()
  end)

  it('runs one `rex do` per keypress, in my session, never starting a server', function()
    local rex = h.rex('nested-4pane', ids.A)
    backend.move('right', {})
    assert.are.equal(1, #rex.argv)
    local argv = rex.argv[1]
    assert.are.same({ 'rex', '--autostart=false', 'do', '-s', h.SESSION, '-e' }, vim.list_slice(argv, 1, 6))
    assert.are.equal('--args', argv[8])
    assert.are.equal(9, #argv)
    local layout = argv[7]:match('^return dofile%("(.-)"%)%.handle%(rex, rex%.args%)$')
    assert.is_truthy(layout)
    assert.are.equal(vim.fn.getcwd() .. '/lua/smart-splits-backend-rex/layout.lua', layout)
  end)

  it('bounds the wait with the configured timeout', function()
    local rex = h.rex('nested-4pane', ids.A)
    backend.move('right', {})
    assert.are.equal(500, rex.sysopts[1].timeout)
    backend.setup({ timeout = 50 })
    backend.resize('right', {})
    assert.are.equal(50, rex.sysopts[2].timeout)
  end)

  it('does not call rex outside a Rex pane', function()
    local rex = h.rex('nested-4pane', ids.A)
    vim.env.REX_BLOCK = nil
    assert.is_false(backend.move('right', {}))
    vim.env.REX_BLOCK = ids.A
    vim.env.REX_SESSION = ''
    assert.is_false(backend.resize('right', {}))
    assert.are.same({}, rex.argv)
  end)

  local failures = {
    ['`rex` is missing'] = { raise = 'ENOENT: no such file or directory (cmd): "rex"' },
    ['rex exits non-zero'] = { result = { code = 3, signal = 0, stdout = '', stderr = 'Error: session not found' } },
    ['rex times out'] = { result = { code = 124, signal = 15, stdout = '', stderr = '' } },
    ['rex prints junk'] = { result = { code = 0, signal = 0, stdout = 'panic: oh no\n', stderr = '' } },
    ['rex prints nothing'] = { result = { code = 0, signal = 0, stdout = '', stderr = '' } },
    ['the reply is not a table'] = { result = { code = 0, signal = 0, stdout = '"handled"\n', stderr = '' } },
    ['handled is not true'] = { result = { code = 0, signal = 0, stdout = '{"handled":"yes"}\n', stderr = '' } },
  }

  for name, opts in pairs(failures) do
    it(('answers not handled, without raising, when %s'):format(name), function()
      h.rex('nested-4pane', ids.A, opts)
      for _, dir in ipairs({ 'left', 'right', 'up', 'down' }) do
        assert.is_false(backend.move(dir, { at_edge = 'wrap' }))
        assert.is_false(backend.resize(dir, { amount = 3 }))
      end
    end)
  end
end)

describe('detect()', function()
  local backend = require('smart-splits-backend-rex')
  local path = vim.env.PATH
  local bin = vim.fn.tempname()

  setup(function()
    vim.fn.mkdir(bin, 'p')
    vim.fn.writefile({ '#!/bin/sh' }, bin .. '/rex')
    vim.uv.fs_chmod(bin .. '/rex', 493) -- 0755
  end)

  after_each(function()
    vim.env.PATH = path
    h.restore()
  end)

  it('is true in a Rex pane with `rex` on $PATH', function()
    vim.env.PATH = bin
    vim.env.REX_SESSION = h.SESSION
    vim.env.REX_BLOCK = ids.A
    assert.is_true(backend.detect())
  end)

  it('is false without $REX_SESSION or $REX_BLOCK', function()
    vim.env.PATH = bin
    vim.env.REX_SESSION = h.SESSION
    assert.is_false(backend.detect())
    vim.env.REX_SESSION = nil
    vim.env.REX_BLOCK = ids.A
    assert.is_false(backend.detect())
  end)

  it('is false without `rex` on $PATH', function()
    vim.env.PATH = vim.fn.tempname()
    vim.env.REX_SESSION = h.SESSION
    vim.env.REX_BLOCK = ids.A
    assert.is_false(backend.detect())
  end)

  it('starts no process', function()
    local rex = h.rex('nested-4pane', ids.A)
    backend.detect()
    assert.are.same({}, rex.argv)
  end)
end)

describe('health()', function()
  local backend = require('smart-splits-backend-rex')
  local real = {}
  local said

  before_each(function()
    said = {}
    for _, level in ipairs({ 'ok', 'info', 'warn', 'error' }) do
      real[level] = vim.health[level]
      vim.health[level] = function(msg)
        table.insert(said, level .. ': ' .. msg)
      end
    end
  end)

  after_each(function()
    for level, fn in pairs(real) do
      vim.health[level] = fn
    end
    h.restore()
  end)

  ---@param level string
  ---@param pattern string
  local function reported(level, pattern)
    for _, line in ipairs(said) do
      if line:find('^' .. level .. ': ') and line:find(pattern) then
        return true
      end
    end
    return false
  end

  it('explains itself outside Rex without calling it', function()
    local rex = h.rex('nested-4pane', ids.A)
    vim.env.REX_SESSION = nil
    backend.health()
    assert.is_true(reported('info', 'not running in a Rex pane'), vim.inspect(said))
    assert.are.same({}, rex.argv)
  end)

  it('finds this pane through a real round trip', function()
    h.rex('nested-4pane-plus-floating', ids.F)
    backend.health()
    assert.is_true(reported('ok', 'tab "main" %(floating layer, 1 panes%)'), vim.inspect(said))
  end)

  it('reports a pane Rex does not know', function()
    h.rex('nested-4pane', 'block:01a1f774-0000-7000-8000-000000000000')
    backend.health()
    assert.is_true(reported('error', 'Rex does not know this pane'), vim.inspect(said))
  end)

  it('reports a failing `rex do`', function()
    h.rex('nested-4pane', ids.A, { result = { code = 1, signal = 0, stdout = '', stderr = 'Error: boom' } })
    backend.health()
    assert.is_true(reported('error', 'Error: boom'), vim.inspect(said))
  end)
end)
