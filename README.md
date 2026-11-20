# smart-splits-backend-rex

A [Rex](https://www.superlogical.com/rex) backend for
[smart-splits.nvim](https://github.com/smart-splits-nvim/smart-splits.nvim) v3, against
[backend protocol 3.0.0](https://github.com/smart-splits-nvim/smart-splits.nvim/blob/master/PROTOCOL.md).

Move and resize across the Neovim/Rex boundary with one set of keys: `<C-hjkl>` walks Neovim's
windows until it runs out of them, then carries on into the neighbouring Rex pane. `<M-hjkl>` resizes
the Neovim window, or the Rex pane once the window fills that axis. At the outer edge of the Rex tab,
the movement keys can stop, wrap, or open a new Rex pane.

## Installation

Two halves have to agree: this plugin, and a few Rex key bindings that let `<C-hjkl>` and
`<M-hjkl>` through to Neovim.

### Neovim

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'smart-splits-nvim/smart-splits.nvim',
  opts = {
    mux = { backend = 'smart-splits-backend-rex' },
    move = { at_edge = 'stop' },
  },
  dependencies = {
    { 'bnew10/backend-rex', main = 'smart-splits-backend-rex', opts = {} },
  },
}
```

To load a local checkout instead, add `dev = true` to the backend's spec: lazy.nvim then takes it from
`backend-rex` under its `dev.path` (`~/projects` by default).

Outside Rex no backend detects, so core warns during `setup()` that none of the configured backends
detected. If you also run Neovim outside Rex, silence that with `mux = { warn_if_unusable = false }`
next to `backend`.

With another multiplexer running inside a Rex pane, list its backend first, since tmux in a Rex pane
still sees `$REX_SESSION` and `$REX_BLOCK`; the first backend that detects wins:

```lua
mux = { backend = { 'smart-splits-backend-tmux', 'smart-splits-backend-rex' } },
```

Then the usual mappings, since smart-splits.nvim binds nothing itself:

```lua
local ss = require('smart-splits')
vim.keymap.set('n', '<C-h>', ss.move_cursor_left)
vim.keymap.set('n', '<C-j>', ss.move_cursor_down)
vim.keymap.set('n', '<C-k>', ss.move_cursor_up)
vim.keymap.set('n', '<C-l>', ss.move_cursor_right)
vim.keymap.set('n', '<M-h>', ss.resize_left)
vim.keymap.set('n', '<M-j>', ss.resize_down)
vim.keymap.set('n', '<M-k>', ss.resize_up)
vim.keymap.set('n', '<M-l>', ss.resize_right)
```

Lazy loading is fine: the backend keeps no state in Rex and registers nothing.

### Rex

Rex has to hand those keys to Neovim, and handle them itself everywhere else. Rex has no per-pane
variable for Neovim to raise, so the binding asks Rex what the pane's foreground program is. This
snippet does both, and moves and resizes non-Neovim panes with this plugin's own Rex-side code, so a
shell pane behaves exactly like Neovim's edge:

```lua
-- ~/.config/rex/init.lua
local TERMINAL = "com.superlogical.terminal"
-- where lazy.nvim installs this plugin; with a local checkout (`dev = true`),
-- point this at the checkout instead
local PLUGIN = os.getenv("HOME") .. "/.local/share/nvim/lazy/backend-rex"
local smart = dofile(PLUGIN .. "/lua/smart-splits-backend-rex/layout.lua")

-- Neovim is the pane's foreground program: it gets the key, and smart-splits
-- hands it back to Rex at its edge
local function in_nvim(block_id)
  local p = rex.block.call(TERMINAL, "process", { block_id = block_id })
  return p ~= nil and p.foreground ~= nil and p.foreground.name == "nvim"
end

for key, dir in pairs({ h = "left", j = "down", k = "up", l = "right" }) do
  rex.bind("ctrl+" .. key, function(ctx)
    if in_nvim(ctx.block_id) then
      return false
    end
    smart.handle(rex, { op = "move", dir = dir, block = ctx.block_id })
    return true
  end)
  rex.bind("alt+" .. key, function(ctx)
    if in_nvim(ctx.block_id) then
      return false
    end
    local size = rex.block.call(TERMINAL, "size", { block_id = ctx.block_id }) or {}
    smart.handle(rex, { op = "resize", dir = dir, block = ctx.block_id, cols = size.columns, rows = size.rows })
    return true
  end)
end
```

Run `rex config check` after editing: a wrong `PLUGIN` path is reported there. `just e2e` runs this
very snippet, out of this README, against a live Neovim pane and a shell pane.

The foreground test misses a Neovim started by a program that stays in the foreground (a file
manager, say), or behind a wrapper script that does not `exec`. Add those names, or match the pane's
title (` - Nvim` with `title` set), if you run Neovim that way.

## Configuration

Every option has a working default, and calling `setup()` is optional. It only stores the options.

```lua
require('smart-splits-backend-rex').setup({
  -- the `rex` CLI to run: a name looked up on $PATH, or an absolute path for a
  -- `rex` that is not on Neovim's $PATH
  bin = 'rex',
  -- refuse to move out of a zoomed Rex tab. Off by default: Rex's own focus
  -- keys leave a zoomed pane and end the zoom, and so does this
  disable_nav_when_zoomed = false,
  -- milliseconds to wait for `rex do`. A call takes ~45 ms; this only bounds a
  -- wedged server, which then costs one stall per keypress at an edge and
  -- one warning
  timeout = 500,
})
```

## How it works

Each move or resize that reaches Neovim's edge starts one process,

```sh
rex --autostart=false do -s "$REX_SESSION" -e 'return dofile(".../layout.lua").handle(rex, rex.args)' --args '<request>'
```

and waits for it. `lua/smart-splits-backend-rex/layout.lua` runs in the `rex` CLI's own Lua 5.1, not
in Neovim: it reads `session.view`, finds the layer whose layout holds `$REX_BLOCK`, decides, acts,
and prints `{"handled": true|false, ...}`. The request carries what only Neovim knows: the operation
and direction, `at_edge`, the resize amount, the pane's size in cells and the cursor's cell.

**Moving** focuses the neighbour by block id with `session.focus_block`. The neighbours are the
panes of the same layer that touch the edge being crossed and share some of it. Of several, the one
level with the Neovim cursor wins, else the one sharing the most of the edge. `focus_direction` is
never used: it acts on the server's active tab, which need not be Neovim's, and cannot say whether it
moved.

**Resizing** moves the nearest border on that axis after the pane (its right or bottom border), else
the nearest before it, by `amount` cells: `left`/`up` lower that split's ratio, `right`/`down` raise
it, by `amount / (pane cells × split size / pane size)`. That is tmux's `resize-pane` rule. The ratio
stays within 0.05..0.95, and the clamp never moves a border against the key: a resize the clamp would
turn into no move, or into a move the other way, is not handled.

`detect()` checks `$REX_SESSION`, `$REX_BLOCK` and that `bin` is executable, and starts nothing. Every
failure is "not handled" and core carries on as if there were no Rex pane that way; nothing raises.
Failing to reach Rex at all (no Rex environment, no `rex`, a non-zero exit, the timeout, a reply that
is not JSON) is a warning, since every edge then stops dead: core echoes each distinct message once,
one line long, and logs every occurrence. An ordinary not-handled reply (an edge, a zoom, the clamp, a
pane Rex no longer knows) is logged at debug level only.

## Behaviour

**`at_edge`.** Core hands its `move.at_edge` setting over first, and applies it inside Neovim only
when the backend did not handle the move.

| `at_edge`       | at the outer edge of the Rex tab                                                   |
| --------------- | ---------------------------------------------------------------------------------- |
| `'stop'`, unset | nothing; core then stops too                                                       |
| `'wrap'`        | focus the farthest pane on the other side that is level with this one              |
| `'split'`       | a new Rex shell beside this pane on that side, focused, in the window's directory  |

With no pane level with this one, `'wrap'` is handed back to core, which wraps among Neovim's windows.

**Zoom.** Moving out of a zoomed pane focuses the neighbour and Rex ends the zoom, as Rex's own focus
keys do, unless `disable_nav_when_zoomed` is set. Resizing in a zoomed tab is never handled: the
border would move under a pane drawn over the whole window.

**Floating panes** navigate among the panes of their own layer, never into the tiled panes beneath.

## Latency

Neovim blocks for the whole round trip. `just e2e` times 24 edge moves per run inside the Neovim under
test, around each backend call, the span core's slow-call diagnostic measures: over six runs (144
moves) the median was 43.2-43.6 ms and single moves took 39.9-69.0 ms, with no failures. Nearly all
of it is starting the `rex` CLI: the same view and focus take 2.5 ms inside an already running `rex
do`. Core's diagnostic flags calls over 100 ms.

## Limitations

- One process per keypress at an edge, so ~45 ms. A persistent `rex do` reading requests on stdin
  would take that to a few ms; `layout.handle` is already the request-to-reply function it would call.
- Swapping buffers never crosses into Rex: protocol v3 does not ask backends to swap.
- The Rex snippet's foreground test is a heuristic, see above.

## Troubleshooting

`:checkhealth smart-splits` names the `rex` it runs, then runs one real request and reports the tab
and layer Rex has this pane in and how long `rex do` took, or why it failed. `:SmartSplitsLog` shows
why each move or resize was not handled (`edge`, `zoomed`, `at limit`, `block not in this session`,
...), and every warning in full.

## Development

`just test` runs the specs: core's protocol conformance suite, and this backend's own, which feed real
`session.view` snapshots (`tests/fixtures`) through the real `layout.lua` behind a fake `vim.system`.
`layout.lua` runs there in a sandbox holding only what the `rex` CLI's Lua 5.1 gives a script, so a
stray `vim.*` or LuaJIT-only call fails the specs rather than Rex. `just fmt-check`, `just lint` and
`just typecheck` run stylua, selene and LuaLS; `just check` runs all four. `just e2e` needs a running
Rex server and never starts one: it builds a scratch session labelled `smart-splits-backend-rex-e2e`,
drives a real Neovim in it with typed keys, and removes the session again. It touches no other
session. An RPC that hangs for 10 s ends the Neovim under test, a watchdog removes the session after
3 minutes, and a session left with that label by a run that died is removed when the next one starts.

## License

MIT
