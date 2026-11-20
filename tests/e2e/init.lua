-- The Neovim under test: `nvim --clean -u tests/e2e/init.lua`, started by
-- run.lua in a Rex pane. Core from deps/, this repo, the usual mappings, and
-- nothing else. run.lua drives it over `--listen` and with keys typed into the pane.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(root .. '/deps/smart-splits.nvim')
vim.o.swapfile = false
vim.o.shadafile = 'NONE'

---Core's options for a case, as `require('e2e').setup(at_edge)`. Every backend
---call lands in the log with its duration (`slow_threshold = 0`), which is how
---run.lua times them.
---@param at_edge string
local function setup(at_edge)
  require('smart-splits').setup({
    mux = { backend = 'smart-splits-backend-rex' },
    move = { at_edge = at_edge },
    log = { level = 'debug', file = vim.env.E2E_LOG },
    diagnostic = { enabled = false, slow_threshold = 0 },
  })
end
package.loaded.e2e = { setup = setup }
setup('stop')

local ss = require('smart-splits')
for key, dir in pairs({ h = 'left', j = 'down', k = 'up', l = 'right' }) do
  vim.keymap.set('n', '<C-' .. key .. '>', ss['move_cursor_' .. dir])
  vim.keymap.set('n', '<M-' .. key .. '>', ss['resize_' .. dir])
end

vim.g.e2e_ready = true
