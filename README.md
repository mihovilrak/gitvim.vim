# gitvim.nvim

> **Status: pre-alpha, under active development.** The scaffolding, test harness and
> plan are in place; the features below are being built. See [Plan.md](Plan.md) for
> the full design and the task checklist.

A VS Code-shaped Git workbench for Neovim, built for LazyVim.

Neovim's Git ecosystem is excellent but fragmented — every individual capability
exists somewhere, but nothing assembles them into one docked, discoverable surface
the way VS Code's Source Control view does. `gitvim.nvim` is that shell: it owns the
sidebar, the graph, the timeline, the commit UI and the remote operations, and
delegates the in-buffer layer to [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim).

```
┌──────────────┬─────────────────┐
│ EXPLORER     │                 │
│  lua/        │     buffer      │
├──────────────┤                 │
│ SCM│GRAPH│TL │  ← winbar tabs  │
│  main ↓2 ↑3  │                 │
│ ▼ Staged   2 │                 │
│  M config.lua│                 │
│  A new.lua   │                 │
│ ▼ Changes  3 │                 │
│  M init.lua  │                 │
│  U scratch.md│                 │
└──────────────┴─────────────────┘
```

## Planned for v1

| Pillar | What it gives you |
|---|---|
| **SCM tab** | Collapsible `Staged` / `Changes` / `Untracked` groups, VS Code status letters (`M A D R U C`) and colors, filetype icons, branch + ahead/behind header, commit box, and stage / unstage / discard / commit / fetch / pull / push |
| **Graph tab** | `git log` rendered with colored per-branch lanes; click a commit to see its files, click a file to open the review view |
| **Timeline tab** | Per-file history via `git log --follow`, through the same lane renderer |
| **Buffer layer** | Themed signs, current-line blame virtual text, and a clickable gutter — double-click a sign to expand the hunk inline |
| **Review view** | Two-pane native `diffmode` with right-aligned `[+]` `[↩]` `[⤢]` buttons per hunk |

Post-MVP, in priority order: merge conflict UI, stashes and branch management,
multi-repo / submodules / worktrees, a neo-tree source adapter, and a zero-dependency
mode. See [Plan.md](Plan.md) §3.

## Requirements

- Neovim **0.11+**
- `git` **2.30+**
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) — required
- [snacks.nvim](https://github.com/folke/snacks.nvim) — optional, used for the sidebar window
- [mini.icons](https://github.com/nvim-mini/mini.icons) — optional, used for filetype icons

Run `:checkhealth gitvim` to verify your setup.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mihovilrak/gitvim.nvim",
  dependencies = { "lewis6991/gitsigns.nvim" },
  cmd = "GitVim",
  keys = {
    { "<leader>gg", "<cmd>GitVim toggle<cr>", desc = "GitVim sidebar" },
  },
  opts = {},
}
```

## Usage

| Command | Does |
|---|---|
| `:GitVim open [tab]` | Open the sidebar (`scm`, `graph`, `timeline`) |
| `:GitVim close` | Close the sidebar |
| `:GitVim toggle` | Toggle the sidebar |

`:GitVim` supports completion for its subcommands.

## Configuration

`opts` is deep-merged over the defaults in
[`lua/gitvim/config.lua`](lua/gitvim/config.lua), which is the authoritative
reference. A brief taste:

```lua
require("gitvim").setup({
  sidebar = {
    position = "left",
    width = 50,
    stack = false,          -- true: share the column with your file explorer
    tabs = { "scm", "graph", "timeline" },
    default_tab = "scm",
  },
  buffer = {
    blame = true,           -- current-line blame virtual text
    clickable_gutter = true, -- double-click a sign to expand the hunk
  },
  keymaps = { enabled = true, prefix = "<leader>g" },
})
```

## Development

```bash
make test        # headless plenary suite (clones deps into .tests/ on first run)
make test-file FILE=tests/gitvim/fixture_spec.lua
make fmt         # stylua
make lint        # luacheck
make docs        # regenerate doc/tags
make all         # fmt-check + lint + test
```

`stylua` and `luacheck` are optional locally — those targets skip with a notice if
the tool is missing, and CI runs both regardless.

Tests build a deterministic throwaway repository via `tests/fixture.lua` (branch,
merge, rename, and a dirty worktree covering every status group including a path
with a space and a non-ASCII character), so assertions can be exact. To poke at one
by hand:

```bash
nvim --headless -u tests/minimal_init.lua \
  -c "lua print(require('fixture').build({ keep = true }).root)" -c "qa!"
```

## Credits

Standing on the shoulders of [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim),
[snacks.nvim](https://github.com/folke/snacks.nvim), [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
and [mini.icons](https://github.com/nvim-mini/mini.icons).

## License

[MIT](LICENSE)
