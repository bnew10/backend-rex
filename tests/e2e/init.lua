-- The Neovim under test: `nvim --clean -u tests/e2e/init.lua`, started by
-- run.lua in a Rex pane. Core from deps/, this repo, the usual mappings, and
-- nothing else. run.lua drives it over `--listen` and with keys typed into the pane.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(root .. '/deps/smart-splits.nvim')
vim.o.swapfile = false
-- run.lua ends this Neovim by this pid when an RPC to it hangs
vim.fn.writefile({ tostring(vim.fn.getpid()) }, vim.env.E2E_PID)
vim.o.shadafile = 'NONE'

local backend = require('smart-splits-backend-rex')

---What run.lua reads and calls over RPC, as `require('e2e')`.
local e2e = { calls = {} }
package.loaded.e2e = e2e

---The backend as core sees it, recording each call core makes: the op, the
---direction, what it returned and how long Neovim was blocked in it, which is
---the span core's own slow-call diagnostic measures.
local recorded = setmetatable({}, { __index = backend })
for _, op in ipairs({ 'move', 'resize' }) do
  recorded[op] = function(direction, opts)
    local start = vim.uv.hrtime()
    local handled = backend[op](direction, opts)
    table.insert(e2e.calls, { op = op, dir = direction, handled = handled, ms = (vim.uv.hrtime() - start) / 1e6 })
    return handled
  end
end

---Core's options for a case. The log file gets every level; nothing below
---error is echoed, so no message can leave a prompt to swallow the next key.
---@param at_edge string
function e2e.setup(at_edge)
  require('smart-splits').setup({
    mux = { backend = recorded },
    move = { at_edge = at_edge },
    log = { level = 'error', file = vim.env.E2E_LOG },
  })
end
e2e.setup('stop')

local ss = require('smart-splits')
for key, dir in pairs({ h = 'left', j = 'down', k = 'up', l = 'right' }) do
  vim.keymap.set('n', '<C-' .. key .. '>', ss['move_cursor_' .. dir])
  vim.keymap.set('n', '<M-' .. key .. '>', ss['resize_' .. dir])
end

vim.g.e2e_ready = true
