-- End-to-end: `nvim -l tests/e2e/run.lua` from the repo root, with a Rex server
-- running. It builds a scratch session laid out like tests/fixtures/nested-4pane
--
--   +--------+--------+
--   | A  .3  | B  .6  |   B runs the Neovim under test (tests/e2e/init.lua)
--   +--------+        |
--   | D      +--------+
--   |        | C      |
--   +--------+--------+
--
-- types real keys into B's terminal, judges each case by what `session.view` and
-- that Neovim report, prints PASS or FAIL per case, and destroys the session.
-- It touches no other session: every command names its own with `-s`. A
-- watchdog removes the session if the run hangs, and a session left with the
-- label by a run that died is removed before this one starts.
--
-- No app shows the scratch session, so nothing would size its terminals and
-- every pane would stay 80x24 whatever its rect. run.lua plays the app's part:
-- after each layout change it sizes every pane to its rect in a WIDTH x HEIGHT
-- window, so Neovim's own size follows the layout as it does on screen.

local ROOT = vim.fn.getcwd()
local LABEL = vim.env.E2E_LABEL or 'smart-splits-backend-rex-e2e'
local SHELL = 'com.superlogical.terminal.shell'
local CTRL = { h = '\8', j = '\10', k = '\11', l = '\12' }
local ALT = { h = '\27h', j = '\27j', k = '\27k', l = '\27l' }
local LATENCY_RUNS = 24
local WIDTH, HEIGHT = 200, 60
-- a whole run takes about 15 s
local WATCHDOG_MS = 180000
local RPC_TIMEOUT_MS = 10000

-- this script may well run in a Rex pane; nothing may default to that session
vim.env.REX_SESSION = nil
vim.env.REX_BLOCK = nil

---`print` in `nvim -l` holds the newline back until the next message.
local function say(fmt, ...)
  io.write(fmt:format(...), '\n')
end

local function fail(fmt, ...)
  error(fmt:format(...), 0)
end

local function expect(ok, fmt, ...)
  if not ok then
    fail(fmt, ...)
  end
end

---@param args string[]
---@return string stdout
local function rex(args)
  local argv = { 'rex', '--autostart=false' }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { text = true, timeout = 15000 }):wait()
  if r.code ~= 0 then
    fail('`rex %s` exited %d: %s', table.concat(args, ' '), r.code, vim.trim(r.stderr or ''))
  end
  return r.stdout
end

---@param fn fun():any
---@param ms integer
---@return any the first truthy value, or nil on timeout
local function poll(fn, ms)
  local deadline = vim.uv.hrtime() + ms * 1e6
  repeat
    local value = fn()
    if value then
      return value
    end
    vim.uv.sleep(20)
  until vim.uv.hrtime() > deadline
  return nil
end

local function session_ids()
  local ids = {}
  for _, s in ipairs(vim.json.decode(rex({ 'session', 'ls', '--json' })).sessions or {}) do
    ids[s.session_id] = s.label or ''
  end
  return ids
end

local before = session_ids()
-- ponytail: two runs at once would remove each other's session; one at a time
for id, label in pairs(before) do
  if label == LABEL then
    say('      removing %s, left labelled %q by a run that did not finish', id, LABEL)
    rex({ 'kill', id })
    before[id] = nil
  end
end

local S = vim.json.decode(rex({ 'new', LABEL, '--json' })).session_id

-- Last resort for a hang nothing below bounds: remove the session and stop.
-- It fires from inside any wait, a blocked RPC included.
local watchdog = assert(vim.uv.new_timer())
watchdog:start(WATCHDOG_MS, 0, function()
  io.write(('FAIL  watchdog: still running after %d s, removing %s\n'):format(WATCHDOG_MS / 1000, S))
  os.execute(('rex --autostart=false kill %s'):format(S))
  os.exit(1)
end)

local function api(method, args)
  return vim.json.decode(rex({ 'api', 'call', '-s', S, method, vim.json.encode(args or vim.empty_dict()) }))
end

local function window()
  return api('session.view').windows[1]
end

local function leaves(node, out)
  out = out or {}
  if node.block_id then
    out[#out + 1] = { id = node.block_id, rect = node.rect }
  else
    leaves(node.split.before, out)
    leaves(node.split.after, out)
  end
  return out
end

local A, B, C, D, nv_block_env
local chan, nv_pid
local results = {}

---Run Lua in the Neovim under test. An RPC cannot be cancelled, so one that
---has not answered in RPC_TIMEOUT_MS ends that Neovim, which closes the
---channel and ends the wait; every later case then fails fast.
local function nv(code, ...)
  local timer = assert(vim.uv.new_timer())
  local timed_out = false
  timer:start(RPC_TIMEOUT_MS, 0, function()
    timed_out = true
    vim.uv.kill(nv_pid, 'sigkill')
  end)
  local ok, result = pcall(vim.rpcrequest, chan, 'nvim_exec_lua', code, { ... })
  timer:close()
  if timed_out then
    fail('Neovim did not answer within %d ms: %s', RPC_TIMEOUT_MS, code)
  end
  if not ok then
    error(result, 0)
  end
  return result
end

local seq = 0
---Type `keys` into B, then a marker command; once Neovim has run the marker
---it has finished with the keys, including any `rex do` they started.
local function press(keys)
  seq = seq + 1
  rex({ 'send', '-s', S, '-b', B, keys .. (':let g:e2e_seq = %d\r'):format(seq) })
  expect(
    poll(function()
      return nv('return vim.g.e2e_seq') == seq
    end, 5000),
    'Neovim did not get through %q',
    keys
  )
end

local function focused()
  return window().focused_block_id
end

local function rect(w, id)
  for _, leaf in ipairs(leaves(w.layers[1].layout)) do
    if leaf.id == id then
      return leaf.rect
    end
  end
end

local function size()
  return nv('return { vim.o.columns, vim.o.lines }')
end

---Size every pane to its rect, as the app would.
local function size_panes()
  rex({
    'do',
    '-s',
    S,
    '-e',
    [[
    local function leaves(n, out)
      if n.block_id then out[#out + 1] = n else leaves(n.split.before, out) leaves(n.split.after, out) end
      return out
    end
    local view = assert(rex.session.view({}))
    for _, leaf in ipairs(leaves(view.windows[1].layers[1].layout, {})) do
      assert(rex.block.call('com.superlogical.terminal', 'resize', {
        block_id = leaf.block_id,
        columns = math.floor(leaf.rect[3] * rex.args.w + 0.5),
        rows = math.floor(leaf.rect[4] * rex.args.h + 0.5),
      }))
    end
  ]],
    '--args',
    vim.json.encode({ w = WIDTH, h = HEIGHT }),
  })
end

---Wait for Neovim's size to stop changing after a layout change.
local function settle()
  local last
  poll(function()
    local now = table.concat(size(), 'x')
    local same = now == last
    last = now
    return same
  end, 2000)
  vim.uv.sleep(50)
end

local function reset()
  local w = window()
  if w.zoomed_block_id then
    api('session.zoom_block', { block_id = w.zoomed_block_id, zoom = false })
  end
  for _, leaf in ipairs(leaves(w.layers[1].layout)) do
    if leaf.id ~= A and leaf.id ~= B and leaf.id ~= C and leaf.id ~= D then
      api('block.close', { block_id = leaf.id })
    end
  end
  api('session.resize_pane', { direction = 'horizontal', before_block_id = A, after_block_id = B, ratio = 0.5 })
  api('session.resize_pane', { direction = 'vertical', before_block_id = A, after_block_id = D, ratio = 0.3 })
  api('session.resize_pane', { direction = 'vertical', before_block_id = B, after_block_id = C, ratio = 0.6 })
  api('session.focus_block', { block_id = B })
  nv(
    [[
    vim.env.REX_BLOCK = ...
    require('smart-splits-backend-rex').setup()
    require('e2e').setup('stop')
    vim.cmd('silent! only!')
    vim.wo.wrap = false
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.fn['repeat']({ ('x'):rep(500) }, 300))
    vim.cmd('normal! ggH0')
  ]],
    nv_block_env
  )
  size_panes()
  settle()
end

local notes = {}

---A detail to print under the current case's verdict.
local function note(fmt, ...)
  notes[#notes + 1] = fmt:format(...)
end

local function case(name, fn)
  notes = {}
  local ok, err = pcall(function()
    reset()
    fn()
  end)
  results[#results + 1] = ok
  say('%s  %s', ok and 'PASS' or 'FAIL', name)
  if not ok then
    note('%s', tostring(err))
  end
  for _, line in ipairs(notes) do
    say('      %s', line)
  end
end

local function wins()
  return nv('return #vim.api.nvim_tabpage_list_wins(0)')
end

local function cases()
  case('move left: across a Neovim split, then into Rex pane A', function()
    nv('vim.cmd("vsplit") vim.cmd("wincmd l") vim.cmd("normal! H")')
    press(CTRL.h)
    expect(nv('return vim.fn.winnr()') == 1, 'Neovim did not move to its left window')
    expect(focused() == B, 'Rex focus left B while Neovim had a window to move to')
    press(CTRL.h)
    expect(focused() == A, 'focus is %s, want A', focused())
  end)

  case('move left: the cursor level with D picks D over A', function()
    nv('vim.cmd("normal! L")')
    press(CTRL.h)
    expect(focused() == D, 'focus is %s, want D', focused())
  end)

  case('move down: across a Neovim split, then into Rex pane C', function()
    nv('vim.cmd("split") vim.cmd("wincmd k")')
    press(CTRL.j)
    expect(nv('return vim.fn.winnr()') == 2, 'Neovim did not move to its lower window')
    expect(focused() == B, 'Rex focus left B while Neovim had a window to move to')
    press(CTRL.j)
    expect(focused() == C, 'focus is %s, want C', focused())
  end)

  case("at_edge 'stop' at the right edge: nothing moves", function()
    local rev = api('session.view').revision
    press(CTRL.l)
    expect(focused() == B, 'focus moved to %s', focused())
    expect(api('session.view').revision == rev, 'the session changed')
    expect(wins() == 1, 'Neovim split')
  end)

  case("at_edge 'wrap' at the right edge: the farthest pane, by cursor row (A)", function()
    nv('require("e2e").setup("wrap")')
    press(CTRL.l)
    expect(focused() == A, 'focus is %s, want A', focused())
    expect(wins() == 1, 'Neovim wrapped too')
  end)

  case("at_edge 'wrap' at the top edge: C", function()
    nv('require("e2e").setup("wrap")')
    press(CTRL.k)
    expect(focused() == C, 'focus is %s, want C', focused())
  end)

  case("at_edge 'split' at the right edge: a new focused Rex pane right of B", function()
    nv('require("e2e").setup("split")')
    press(CTRL.l)
    local w = window()
    local all = leaves(w.layers[1].layout)
    expect(#all == 5, '%d panes, want 5', #all)
    local new = w.focused_block_id
    expect(new ~= A and new ~= B and new ~= C and new ~= D, 'focus is on an old pane')
    local b, n = rect(w, B), rect(w, new)
    expect(math.abs(n[1] - (b[1] + b[3])) < 1e-6 and n[2] == b[2], 'the new pane is not right of B')
    expect(wins() == 1, 'Neovim split too')
  end)

  case('zoomed tab: moves anyway and Rex ends the zoom', function()
    api('session.zoom_block', { block_id = B, zoom = true })
    press(CTRL.h)
    local w = window()
    expect(w.focused_block_id == A, 'focus is %s, want A', w.focused_block_id)
    expect(w.zoomed_block_id == nil, 'still zoomed')
  end)

  case('zoomed tab with disable_nav_when_zoomed: not handled', function()
    nv('require("smart-splits-backend-rex").setup({ disable_nav_when_zoomed = true })')
    api('session.zoom_block', { block_id = B, zoom = true })
    press(CTRL.h)
    local w = window()
    expect(
      w.focused_block_id == B and w.zoomed_block_id == B,
      'focus %s, zoom %s',
      w.focused_block_id,
      w.zoomed_block_id
    )
  end)

  ---@param key string
  ---@param axis 1|2 columns or lines
  ---@param grow integer +1 if B should grow
  local function resize_case(key, axis, grow)
    local w0, before_cells = window(), size()[axis]
    press(ALT[key])
    size_panes()
    expect(
      poll(function()
        return size()[axis] ~= before_cells
      end, 2000),
      'Neovim was not resized'
    )
    settle()
    local w1, after_cells = window(), size()[axis]
    local k = axis + 2 -- rect w or h
    local moved = (rect(w1, B)[k] - rect(w0, B)[k]) * (axis == 1 and WIDTH or HEIGHT)
    note(
      'B %s %d -> %d, its rect moved %.2f cells',
      axis == 1 and 'columns' or 'lines',
      before_cells,
      after_cells,
      moved
    )
    expect(math.abs(moved - 3 * grow) < 0.5, 'the rect moved %.2f cells, want %d', moved, 3 * grow)
    expect(math.abs(after_cells - before_cells - 3 * grow) <= 1, 'Neovim went %d -> %d', before_cells, after_cells)
  end

  case('resize right by 3 cells: the border left of B moves right', function()
    resize_case('l', 1, -1)
  end)

  case('resize down by 3 cells: the border under B moves down', function()
    resize_case('j', 2, 1)
  end)

  case('resize clamps the ratio at 0.05, then stops', function()
    press('100' .. ALT.h)
    local w = window()
    local a = rect(w, A)
    expect(math.abs(a[3] - 0.05) < 1e-9, 'A is %.6f wide, want 0.05', a[3])
    local rev = api('session.view').revision
    press(ALT.h)
    expect(api('session.view').revision == rev, 'resized past the clamp')
  end)

  case('a bogus $REX_BLOCK: not handled, core splits Neovim instead', function()
    nv('vim.env.REX_BLOCK = "block:01a1f774-0000-7000-8000-000000000000" require("e2e").setup("split")')
    local rev = api('session.view').revision
    press(CTRL.h)
    expect(focused() == B, 'focus moved to %s', focused())
    expect(api('session.view').revision == rev, 'the session changed')
    expect(wins() == 2, 'core did not fall back to a Neovim split')
  end)

  case(('latency: %d edge moves into Rex'):format(LATENCY_RUNS), function()
    nv("require('e2e').calls = {}")
    local failures = 0
    for i = 1, LATENCY_RUNS do
      api('session.focus_block', { block_id = B })
      local key, want = CTRL.h, A
      if i % 2 == 0 then
        key, want = CTRL.j, C
      end
      press(key)
      if focused() ~= want then
        failures = failures + 1
      end
    end
    local calls = nv("return require('e2e').calls")
    expect(#calls == LATENCY_RUNS, 'core made %d backend calls, want %d', #calls, LATENCY_RUNS)
    local ms = vim.tbl_map(function(call)
      return call.ms
    end, calls)
    table.sort(ms)
    local n = #ms
    local median = n % 2 == 1 and ms[(n + 1) / 2] or (ms[n / 2] + ms[n / 2 + 1]) / 2
    note(
      'Neovim blocked per move: median %.1f ms, range %.1f-%.1f ms, n=%d, failures %d',
      median,
      ms[1],
      ms[n],
      n,
      failures
    )
    expect(failures == 0, '%d moves did not land', failures)
  end)

  case("the README's Rex snippet: Neovim keeps its keys, a shell pane moves and resizes", function()
    local readme = table.concat(vim.fn.readfile(ROOT .. '/README.md'), '\n')
    local snippet = readme:match('```lua\n(%-%- ~/%.config/rex/init%.lua\n.-)```')
    expect(snippet, 'no Rex snippet in the README')
    local file = vim.fn.tempname() .. '.lua'
    vim.fn.writefile(vim.split(snippet:gsub('local PLUGIN = [^\n]*', ('local PLUGIN = %q'):format(ROOT)), '\n'), file)
    local got = vim.json.decode(rex({
      'do',
      '-s',
      S,
      '-e',
      [[
      local a, keys = rex.args, {}
      -- collect the handlers instead of binding them, then press them by hand
      rex.bind = function(key, fn) keys[key] = fn end
      dofile(a.snippet)
      local function tiled() return rex.session.view({}).windows[1] end
      local got = {}
      got.nvim_ctrl = keys['ctrl+h']({ block_id = a.B })
      got.nvim_alt = keys['alt+l']({ block_id = a.B })
      got.shell_ctrl = keys['ctrl+l']({ block_id = a.A })
      got.focus = tiled().focused_block_id
      got.shell_alt = keys['alt+l']({ block_id = a.A })
      got.ratio = tiled().layers[1].layout.split.ratio
      return got
    ]],
      '--args',
      vim.json.encode({ snippet = file, A = A, B = B }),
    }))
    expect(got.nvim_ctrl == false and got.nvim_alt == false, 'it took a key from Neovim: %s', vim.inspect(got))
    expect(got.shell_ctrl == true and got.focus == B, 'ctrl+l in A did not focus B: %s', vim.inspect(got))
    -- A is 100 of the window's 200 columns, so 3 cells is 0.015 of the outer split
    expect(got.shell_alt == true and math.abs(got.ratio - 0.515) < 1e-9, 'alt+l in A: %s', vim.inspect(got))
  end)

  case('core logged no backend warnings or errors', function()
    for _, line in ipairs(vim.fn.readfile(nv('return vim.env.E2E_LOG'))) do
      expect(not line:find(' ERROR ') and not line:find(' WARN '), '%s', line)
    end
  end)
end

local ok, err = pcall(function()
  local first = vim.json.decode(rex({ 'api', 'call', '-s', S, 'session.view', '{}' })).windows[1].window_id
  local sock = vim.fn.tempname() .. '.sock'
  local pidfile = vim.fn.tempname() .. '.pid'
  local nvim = {
    '/usr/bin/env',
    'E2E_LOG=' .. vim.fn.tempname() .. '.log',
    'E2E_PID=' .. pidfile,
    vim.v.progpath,
    '--clean',
    '-u',
    ROOT .. '/tests/e2e/init.lua',
    '--listen',
    sock,
  }
  rex({
    'do',
    '-s',
    S,
    '-e',
    [[
    local a = rex.args
    local function pane(command)
      return rex.layout.block({ flavor = a.shell, options = { command = command, cwd = a.cwd, exit = { on_completion = false } } })
    end
    local sh = { '/bin/sh' }
    local w, err = rex.session.new_window({ layout = rex.layout.horizontal(0.5,
      rex.layout.vertical(0.3, pane(sh), pane(sh)),
      rex.layout.vertical(0.6, pane(a.nvim), pane(sh))) })
    if not w then error(err, 0) end
    local _, cerr = rex.session.close_window({ window_id = a.first })
    if cerr then error(cerr, 0) end
  ]],
    '--args',
    vim.json.encode({ shell = SHELL, nvim = nvim, cwd = ROOT, first = first }),
  })

  for _, leaf in ipairs(leaves(window().layers[1].layout)) do
    local x, y = leaf.rect[1], leaf.rect[2]
    if x < 0.25 then
      if y < 0.1 then
        A = leaf.id
      else
        D = leaf.id
      end
    elseif y < 0.1 then
      B = leaf.id
    else
      C = leaf.id
    end
  end
  expect(A and B and C and D, 'the layout did not come out as four panes')

  -- the pid first: from the first RPC on, a hang ends that Neovim
  nv_pid = poll(function()
    return vim.fn.filereadable(pidfile) == 1 and tonumber(vim.fn.readfile(pidfile)[1])
  end, 10000)
  chan = nv_pid
    and poll(function()
      local connected, id = pcall(vim.fn.sockconnect, 'pipe', sock, { rpc = true })
      return connected and id > 0 and id
    end, 10000)
  if not chan or not poll(function()
    return nv('return vim.g.e2e_ready')
  end, 10000) then
    fail('Neovim did not start in B:\n%s', rex({ 'capture', '-s', S, '-b', B, '--trim' }))
  end
  nv_block_env = nv('return vim.env.REX_BLOCK')
  expect(nv_block_env == B, 'Neovim has $REX_BLOCK %s, want %s', tostring(nv_block_env), B)

  cases()
end)
if not ok then
  results[#results + 1] = false
  say('FAIL  setup: %s', tostring(err))
end

watchdog:close()
pcall(rex, { 'kill', S })
local after = session_ids()
results[#results + 1] = after[S] == nil
say('%s  scratch session removed', after[S] == nil and 'PASS' or 'FAIL')
-- Other tools may come and go while this runs, so a vanished session is
-- reported, not failed: every command above names the scratch session.
for id, label in pairs(before) do
  if not after[id] then
    say('      %s (%s) ended during the run', id, label)
  end
end

local failed = #vim.tbl_filter(function(r)
  return not r
end, results)
say('%d passed, %d failed', #results - failed, failed)
os.exit(failed == 0 and 0 or 1)
