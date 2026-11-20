---@module 'smart-splits.backend'

---The Neovim side: package what only Neovim knows into a request, hand it to
---`layout.lua` running in one `rex do` process, and read back whether it was
---handled. The layout, the decision and the action all happen over there, in
---one process, because starting the `rex` CLI is most of the cost.

---The Rex-side file, by absolute path: `rex do` runs in its own interpreter and
---cannot see Neovim's runtimepath.
local HERE = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local LAYOUT = vim.fs.joinpath(HERE, 'layout.lua')

---The one-shot wrapper `rex do` evaluates. A persistent mode would loop over
---stdin calling the same `handle`.
local WRAPPER = ('return dofile(%q).handle(rex, rex.args)'):format(LAYOUT)

---@class RexBackend.Config
---@field disable_nav_when_zoomed boolean refuse to move out of a zoomed Rex tab
---@field timeout integer milliseconds to wait for `rex do` before giving up

---@type RexBackend.Config
local DEFAULTS = {
  -- Rex's own focus keys move out of a zoomed pane and end the zoom, so do the same
  disable_nav_when_zoomed = false,
  -- a call takes ~45 ms; this only bounds a wedged server, which then costs one
  -- stall per keypress at an edge instead of a frozen editor
  timeout = 500,
}

local M = {
  name = 'smart-splits-backend-rex',
  protocol_version = '3.0.0',
  ---@type RexBackend.Config
  config = vim.deepcopy(DEFAULTS),
}

---Store options and return. Core never calls this; it may run for a backend
---that is never selected, so it does nothing else.
---@param opts? { disable_nav_when_zoomed?: boolean, timeout?: integer }
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', DEFAULTS, opts or {})
end

---@param name string
---@return string|nil
local function env(name)
  local value = vim.env[name]
  return value ~= '' and value or nil
end

---@param fmt string
local function debug_log(fmt, ...)
  local ok, log = pcall(require, 'smart-splits.log')
  if ok then
    log.debug(fmt, ...)
  end
end

---Run one request through `rex do`. Anything but a well-formed reply (no Rex
---environment, no `rex`, a non-zero exit, a timeout, junk on stdout) comes back
---as `nil, why`; nothing here raises.
---@param req table
---@return table|nil reply
---@return string|nil why
local function ask(req)
  local session, block = env('REX_SESSION'), env('REX_BLOCK')
  if not session or not block then
    return nil, 'not in a Rex pane'
  end
  req.block = block
  local argv = { 'rex', '--autostart=false', 'do', '-s', session, '-e', WRAPPER, '--args', vim.json.encode(req) }
  local ran, result = pcall(function()
    return vim.system(argv, { text = true, timeout = M.config.timeout }):wait()
  end)
  if not ran then
    return nil, tostring(result)
  end
  if type(result) ~= 'table' then
    return nil, ('rex do gave no result: %s'):format(vim.inspect(result))
  end
  -- vim.system's own timeout: it kills `rex` and reports 124
  if result.code == 124 then
    return nil, ('rex do timed out after %d ms'):format(M.config.timeout)
  end
  if result.code ~= 0 then
    return nil, ('rex do exited %s: %s'):format(tostring(result.code), vim.trim(result.stderr or ''))
  end
  local decoded, reply = pcall(vim.json.decode, result.stdout or '')
  if not decoded or type(reply) ~= 'table' then
    return nil, ('unreadable reply from rex do: %q'):format(result.stdout or '')
  end
  return reply
end

---@param req table
---@return boolean
local function run(req)
  local reply, why = ask(req)
  if not reply then
    debug_log('rex: %s %s not handled: %s', req.op, req.dir, why)
    return false
  end
  debug_log('rex: %s %s -> %s', req.op, req.dir, reply.did or reply.why)
  return reply.handled == true
end

---Cheap and side-effect free: Rex sets both variables in every terminal it starts.
---@return boolean
function M.detect()
  return env('REX_SESSION') ~= nil and env('REX_BLOCK') ~= nil and vim.fn.executable('rex') == 1
end

---Move to the Rex pane across Neovim's edge. Core calls this only at that edge.
---@param direction SmartSplitsDirection
---@param opts? SmartSplitsBackendMoveOpts
---@return boolean
function M.move(direction, opts)
  opts = opts or {}
  local pos = vim.fn.win_screenpos(0)
  return run({
    op = 'move',
    dir = direction,
    at_edge = opts.at_edge,
    disable_nav_when_zoomed = M.config.disable_nav_when_zoomed,
    -- the cursor's cell in the pane: of several panes across the edge, the one
    -- level with the cursor wins
    row = pos[1] + vim.fn.winline() - 2,
    col = pos[2] + vim.fn.wincol() - 2,
    rows = vim.o.lines,
    cols = vim.o.columns,
    -- a new pane starts where this Neovim is, as tmux's `#{pane_current_path}`
    cwd = opts.at_edge == 'split' and vim.uv.cwd() or nil,
  })
end

---Move the Rex border by `opts.amount` cells. Core calls this only when the
---Neovim window fills that axis.
---@param direction SmartSplitsDirection
---@param opts? SmartSplitsBackendResizeOpts
---@return boolean
function M.resize(direction, opts)
  opts = opts or {}
  return run({ op = 'resize', dir = direction, amount = opts.amount, rows = vim.o.lines, cols = vim.o.columns })
end

---Under core's `:checkhealth smart-splits` header. Runs one real `rex do`
---when inside Rex, which checks the whole path a keypress takes.
function M.health()
  if vim.fn.executable('rex') ~= 1 then
    vim.health.error('`rex` is not on $PATH')
  end
  local session, block = env('REX_SESSION'), env('REX_BLOCK')
  if not session or not block then
    vim.health.info('$REX_SESSION or $REX_BLOCK is not set: this Neovim is not running in a Rex pane')
  else
    local start = vim.uv.hrtime()
    local reply, why = ask({ op = 'locate' })
    local ms = (vim.uv.hrtime() - start) / 1e6
    if not reply then
      vim.health.error(('`rex do` failed: %s'):format(why))
    elseif reply.handled ~= true then
      vim.health.error(('Rex does not know this pane (%s): %s'):format(block, tostring(reply.why)))
    else
      vim.health.ok(
        ('pane %s is in tab %s (%s layer, %s panes%s), `rex do` answered in %.0f ms'):format(
          block,
          vim.inspect(reply.window),
          tostring(reply.layer),
          tostring(reply.panes),
          reply.zoomed and ', zoomed' or '',
          ms
        )
      )
    end
  end
  vim.health.info('Rex passes ctrl/alt+h/j/k/l to Neovim only if its key bindings do, see the README')
  vim.health.info(('disable_nav_when_zoomed: %s'):format(vim.inspect(M.config.disable_nav_when_zoomed)))
  vim.health.info(('timeout: %s ms'):format(vim.inspect(M.config.timeout)))
end

return M
