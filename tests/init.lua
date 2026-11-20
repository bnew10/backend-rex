-- Test initialization
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(vim.env.SMART_SPLITS_DIR)
package.path = table.concat({ root .. '/?.lua', root .. '/?/init.lua', package.path }, ';')
vim.opt.shadafile = 'NONE'
vim.lsp.log.set_level('off')

-- `just test` is often run from a Rex pane: without this the specs would drive
-- the live session they were started from
vim.env.REX_SESSION = nil
vim.env.REX_BLOCK = nil

-- core logs every backend call to a file in the user's own state directory, and
-- echoes the warnings the failure specs provoke on purpose; neither belongs to a test run
require('smart-splits').setup({ log = { level = 'error', file = false } })
