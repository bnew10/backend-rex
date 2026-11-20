---A fake Rex for the specs. It replaces `vim.system`, so the backend's own
---argv, timeout and JSON go through unchanged, and answers each `rex do` by
---running the wrapper the backend passed with `-e`, which loads the real
---`layout.lua`, against a `rex` API that serves a real `session.view` snapshot
---and records every other call. Specs then assert on what core sees (the
---boolean) and on what Rex would have received (the request, the calls).

local M = {}

M.SESSION = 'session:01a1f774-070b-7eb1-885a-5daddf289927'

---Block ids in the fixtures, see tests/fixtures/LAYOUT.txt.
M.ids = {
  A = 'block:01a1f774-070c-71de-8ff7-c917287b2c3f',
  B = 'block:01a1f774-413c-7624-a5e9-4b4e7333457d',
  C = 'block:01a1f774-4166-7f0a-ae07-aee766e47765',
  D = 'block:01a1f774-4191-776d-91cf-6845eca401c1',
  F = 'block:01a1f775-401d-7641-b9b7-a3137310a55e',
  E = 'block:01a1f775-12fb-7297-9c5a-a21fb9c236b8',
}

---@param name string fixture file name without `.json`
---@return table
function M.fixture(name)
  local path = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'fixtures', name .. '.json')
  return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

---A fixture mirrored across the diagonal: x and y, w and h, and the split
---directions swap, so every left/right case becomes an up/down one.
---@param name string
---@return table
function M.transposed(name)
  local function flip(node)
    node.rect = { node.rect[2], node.rect[1], node.rect[4], node.rect[3] }
    if node.split then
      node.split.direction = node.split.direction == 'horizontal' and 'vertical' or 'horizontal'
      flip(node.split.before)
      flip(node.split.after)
    end
  end
  local view = M.fixture(name)
  for _, window in ipairs(view.windows) do
    for _, layer in ipairs(window.layers) do
      flip(layer.layout)
    end
  end
  return view
end

local real_system = vim.system

---@param argv string[]
---@param flag string
---@return string|nil
local function flag_value(argv, flag)
  for i, arg in ipairs(argv) do
    if arg == flag then
      return argv[i + 1]
    end
  end
  return nil
end

---Put Neovim in the pane `block` of a fake session showing fixture `view`.
---@param view string|table fixture name or a `session.view` table
---@param block string the pane Neovim runs in, `$REX_BLOCK`
---@param opts? { result?: table, raise?: string, call_error?: string }
---  `result`: what `vim.system():wait()` returns instead of running the wrapper;
---  `raise`: make `vim.system` throw, as it does when `rex` is missing;
---  `call_error`: make every call but `view` fail with this message
function M.rex(view, block, opts)
  opts = opts or {}
  local state = {
    view = type(view) == 'string' and M.fixture(view) or view,
    ---every `rex do` argv
    argv = {},
    ---every `vim.system` options table
    sysopts = {},
    ---every decoded `--args` request
    requests = {},
    ---every `rex.session` call but `view`, as `{ method, args }`
    calls = {},
  }

  local fake = {
    session = setmetatable({}, {
      __index = function(_, method)
        return function(args)
          if method == 'view' then
            return vim.deepcopy(state.view)
          end
          table.insert(state.calls, { method = method, args = args })
          if opts.call_error then
            return nil, opts.call_error
          end
          return { revision = 2 }
        end
      end,
    }),
  }

  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(argv, sysopts)
    if opts.raise then
      error(opts.raise)
    end
    table.insert(state.argv, argv)
    table.insert(state.sysopts, sysopts)
    local result = opts.result
    if not result then
      local req = vim.json.decode(assert(flag_value(argv, '--args')))
      table.insert(state.requests, req)
      fake.args = req
      local chunk = assert(loadstring(assert(flag_value(argv, '-e'))))
      setfenv(chunk, setmetatable({ rex = fake }, { __index = getfenv(0) }))
      result = { code = 0, signal = 0, stdout = vim.json.encode(chunk()) .. '\n', stderr = '' }
    end
    return {
      wait = function()
        return result
      end,
    }
  end

  vim.env.REX_SESSION = M.SESSION
  vim.env.REX_BLOCK = block

  ---the calls made with `method`
  function state.sent(method)
    return vim.tbl_filter(function(c)
      return c.method == method
    end, state.calls)
  end

  return state
end

---Undo `rex()` and the backend's options.
function M.restore()
  vim.system = real_system
  vim.env.REX_SESSION = nil
  vim.env.REX_BLOCK = nil
  require('smart-splits-backend-rex').setup()
end

local MOTIONS = { top = 'ggH0', bottom = 'ggL0', left = 'gg0', right = 'ggg$' }

---Put the cursor on the top or bottom screen row, or the first or last screen
---column, of a one-window layout.
---@param where 'top'|'bottom'|'left'|'right'
function M.cursor(where)
  vim.cmd('silent! only')
  vim.wo.wrap = false
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.fn['repeat']({ ('x'):rep(500) }, 200))
  vim.cmd('normal! ' .. MOTIONS[where])
end

return M
