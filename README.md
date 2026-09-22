# gitvim.nvim

A VS Code-shaped Git workbench for Neovim, built for LazyVim.

<!-- Record with e.g. `vhs` or `asciinema` + `agg` and save as doc/demo.gif. -->
![gitvim.nvim: staging, the commit graph and the review view](doc/demo.gif)

Neovim's Git ecosystem is excellent but fragmented — every individual capability
exists somewhere, but nothing assembles them into one docked, discoverable surface
the way VS Code's Source Control view does. `gitvim.nvim` is that shell: it owns the
sidebar, the graph, the timeline, the commit UI and the remote operations, and
delegates the in-buffer layer to [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim).

```
┌───────────────────┬─────────────────┐
│ EXPLORER          │                 │
│  lua/             │                 │
├───────────────────┤     buffer      │
│ Files [/] Git Buf │  ← winbar tabs  │
│ ▼ SOURCE CONTROL  │                 │
│   main ↓2 ↑3      │                 │
│  ▼ Staged      2  │                 │
│    M config.lua   │                 │
│    A new.lua      │                 │
│  ▼ Changes     3  │                 │
│    M init.lua     │                 │
│    U scratch.md   │                 │
│ ▶ GRAPH           │                 │
│ ▶ TIMELINE        │                 │
└───────────────────┴─────────────────┘
```

## Features

| Pillar | What it gives you |
|---|---|
| **Sidebar** | Four activity tabs — **Files** (a file tree), **Search** (pattern with case / word / regex toggles, replace, include and exclude globs), **Git**, and **Buffers** (the open buffer list) — in one docked window, clickable and fully keyboard-driven |
| **Source Control** | The Git tab's first section: collapsible `Staged` / `Changes` / `Untracked` groups, VS Code status letters (`M A D R U C`) and colors, filetype icons, branch + ahead/behind header, commit box, and stage / unstage / discard / commit / fetch / pull / push |
| **Graph** | `git log` rendered with colored per-branch lanes and ref badges; click a commit to see its files, click a file to open the review view |
| **Timeline** | Per-file history via `git log --follow`, through the same lane renderer |
| **Buffer layer** | Themed signs, current-line blame virtual text, and a clickable gutter — double-click a sign to expand the hunk inline |
| **Review view** | Two-pane native `diffmode` (index \| working tree, or HEAD \| index for staged rows) with right-aligned `[+]` `[−]` `[↩]` `[⤢]` buttons per hunk — stage, unstage, revert, expand |

git always runs off the main loop. On a 10,000-commit repository with 1,000+
changed files the sidebar paints in about 65 ms and a refresh never blocks the
editor for more than about 12 ms (`make bench`, see
[`:h gitvim-performance`](doc/gitvim.txt)).

Post-v0.1, in priority order: merge conflict UI, stashes and branch management,
multi-repo / submodules / worktrees, a neo-tree source adapter, and a zero-dependency
mode. See [Plan.md](Plan.md) §3.

## Requirements

- Neovim **0.11+**
- `git` **2.30+**
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) — required
- [snacks.nvim](https://github.com/folke/snacks.nvim) — optional, used for pickers and notifications
- [mini.icons](https://github.com/nvim-mini/mini.icons) or
  [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) — optional, used for filetype icons
- [ripgrep](https://github.com/BurntSushi/ripgrep) — optional, the Search tab falls back to `git grep`
- A [Nerd Font](https://www.nerdfonts.com/) for the default glyphs, or `icons.style = "ascii"`

Run `:checkhealth gitvim` to verify your setup. It checks the editor version and
`'mouse'`, every dependency (including a gitsigns too old for the calls gitvim
makes), your configuration (`setup()` never called, `icons.style` against
`vim.g.have_nerd_font`, the clickable gutter with the mouse off, buffer keymaps
that yield to an existing mapping) and the repository around the current buffer,
down to a missing `user.name` / `user.email`.

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

### LazyVim

Drop this into `lua/plugins/gitvim.lua`. gitsigns and snacks are already part of
LazyVim, and LazyVim's own `<leader>g…` maps win over gitvim's buffer maps
(gitvim never shadows a mapping), so this spec moves gitvim's to `<leader>v`:

```lua
return {
  "mihovilrak/gitvim.nvim",
  dependencies = { "lewis6991/gitsigns.nvim" },
  cmd = "GitVim",
  keys = {
    { "<leader>gv", "<cmd>GitVim toggle<cr>", desc = "GitVim sidebar" },
  },
  opts = {
    keymaps = { prefix = "<leader>v" },
  },
}
```

`setup()` is optional with the defaults; the first `:GitVim` initialises the
plugin. Full reference: `:h gitvim`.

## Usage

| Command | Does |
|---|---|
| `:GitVim open [tab]` | Open the sidebar (`files`, `search`, `git`, `buffers`) |
| `:GitVim close` | Close the sidebar |
| `:GitVim toggle` | Toggle the sidebar |
| `:GitVim blame` | Toggle current-line blame |
| `:GitVim blame-commit` | Select the current line's commit in the Git graph |
| `:GitVim stage` / `unstage` / `discard` | Stage, unstage or discard the current file |
| `:GitVim stage-all` / `unstage-all` / `discard-all` | The same for every change |
| `:GitVim commit [--amend] [--signoff]` | Open the commit message editor |
| `:GitVim fetch` / `pull` / `push` | Remote operations; `push` publishes a branch that has no upstream |
| `:GitVim checkout` | Switch to another local branch |
| `:GitVim review [rev]` | Review the current file against the index, or against `rev` |

`:GitVim` supports completion for its subcommands and the commit flags.
Every discard asks for confirmation first (`scm.confirm_discard`).

### Sidebar

These work on every tab:

| Key | Does |
|---|---|
| `<Tab>` / `<S-Tab>` | Next / previous tab |
| `1` `2` `3` `4` | Jump to a tab, in `sidebar.tabs` order |
| `<CR>` / `<2-LeftMouse>` | The row's action (single clicks hit buttons) |
| `R` | Refresh |
| `q` | Close the sidebar |

### Search

The Search tab runs as you edit the form, through
[ripgrep](https://github.com/BurntSushi/ripgrep) when it is on `PATH` and
`git grep` otherwise. Results are grouped per file and capped at
`search.max_results`. Include / Exclude take comma-separated globs with rg's
semantics (`docs/**` for everything under `docs`). With a Replace text, every
match shows its replacement inline; in regex mode rg expands capture groups
(`$1`, `${name}`, and `${0}` for the whole match).

| Key | Does | Key | Does |
|---|---|---|---|
| `<CR>` / `i` | Edit a field | `<CR>` | Fold a file, or open a match |
| `<M-c>` | Toggle case-sensitive | `r` | Replace the line (a file header: the file) |
| `<M-w>` | Toggle whole word | `A` | Replace all (or click `[replace all]`) |
| `<M-r>` | Toggle regex | `R` | Run the search again |
| `<C-l>` | Clear the search | | |

Replacing a file or everything asks first (`search.confirm_replace`). Each
file is changed in a single undo step and written, unless its buffer already
had unsaved edits, which stay unsaved. Lines that changed since the search are
skipped.

### Source Control

The Git tab's SOURCE CONTROL section opens with a commit line (the draft's
subject and a **Commit** button), then one group per porcelain state. File
rows and group headers carry right-aligned buttons: `[+]` stage, `[−]` unstage,
`[↩]` discard (`[+]` `[-]` `[<]` with ASCII icons). Click them, or use the keys:

| Key | Does | Key | Does |
|---|---|---|---|
| `<CR>` | Open the review view | `c` | Commit |
| `s` | Stage the row (a header: the group) | `C` | Amend HEAD |
| `u` | Unstage the row | `b` | Check out a branch |
| `x` | Discard the row | `f` | Fetch |
| `-` | Toggle staged | `p` | Pull |
| `S` / `U` / `X` | Stage / unstage / discard all | `P` | Push |
| `za` / `<Space>` | Fold a group or section | `o` | Open the file itself |

The commit editor is a floating `gitcommit` buffer: `<C-Enter>` (or `<C-s>`)
commits, `q` / `<Esc>` closes. What you type is kept as the repository's
draft, so closing it loses nothing. The sidebar refreshes itself after
external `git` commands, on `BufWritePost` and on `FocusGained`.

### Graph and Timeline

GRAPH shows every branch, remote and tag with colored lanes, loading
`graph.page_size` commits at a time as you scroll. TIMELINE follows the file in
the active window (`t` pins it) and carries on past renames.

| Key | Does |
|---|---|
| `<CR>` | GRAPH: list a commit's files, or review a listed file against its parent. TIMELINE: review that revision |
| `za` / `<Space>` | Fold or unfold a commit's files |
| `o` | Open a listed file as it is in the worktree |
| `gw` | TIMELINE: review the revision against the working tree |
| `t` | TIMELINE: pin / unpin the file |

### Review view

| Key | Does |
|---|---|
| `]h` / `[h` | Next / previous hunk |
| `s` / `u` | Stage / unstage the hunk |
| `x` | Revert the hunk (after confirmation) |
| `o` | Expand / collapse the context |
| `R` | Reload both panes |
| `q` | Close the review |

The default in-buffer mappings use `keymaps.prefix` (`<leader>g`):

| Mapping | Does |
|---|---|
| `<leader>ghs` | Stage the hunk under the cursor |
| `<leader>ghu` | Undo the last staged hunk |
| `<leader>ghr` | Reset the hunk under the cursor |
| `<leader>ghp` | Preview the hunk inline |
| `<leader>ghb` | Show line blame |
| `<leader>gtb` | Toggle current-line blame |
| `<leader>ghB` | Select the blamed commit in GRAPH |
| `<leader>gs` / `gu` / `gx` | Stage / unstage / discard the current file |
| `<leader>gS` | Stage all changes |
| `<leader>gc` / `gC` | Commit / amend |
| `<leader>gf` / `gp` / `gP` | Fetch / pull / push |

Double-click a gitsign to preview its hunk inline, or right-click it for the
hunk action menu. A mapping is only made where the key is free, so gitvim never shadows your own
or LazyVim's `<leader>g` mappings; custom status columns are preserved too.

## Configuration

`opts` is deep-merged over the defaults in
[`lua/gitvim/config.lua`](lua/gitvim/config.lua); `:h gitvim-config` documents
every key. The ones you are most likely to want:

```lua
require("gitvim").setup({
  sidebar = {
    position = "left",       -- or "right"
    width = 40,
    stack = false,           -- true: share the column with your file explorer
    tabs = { "files", "search", "git", "buffers" },
    default_tab = "git",
    close_on_open = false,
  },
  files = { root = "repo", show_hidden = true, show_ignored = false },
  search = { max_results = 2000, confirm_replace = true },
  git = {
    -- Sections of the Git tab, and which of them start folded.
    sections = { "scm", "graph", "timeline" },
    collapsed = { "graph", "timeline" },
  },
  buffers = { sort = "mru" }, -- "mru", "number" or "name"
  scm = {
    groups = { "merge", "staged", "changes", "untracked" },
    row_actions = true,      -- [+] [-] [<] buttons on rows and group headers
    confirm_discard = true,
    signoff = false,         -- add Signed-off-by to every commit
  },
  graph = { page_size = 256, date_format = "relative", show_refs = true },
  timeline = { page_size = 128, follow_renames = true, follow_buffer = true },
  review = { hunk_actions = true },
  buffer = {
    signs = true,            -- theme gitsigns with gitvim's colors
    blame = true,            -- current-line blame virtual text
    blame_format = "<author>, <author_time:%R> - <summary>",
    clickable_gutter = true, -- double-click a sign to expand the hunk
  },
  refresh = { debounce = 50, watch_gitdir = true },
  icons = {
    style = "auto",          -- "nerd", "ascii", or "auto" (vim.g.have_nerd_font)
    overrides = {},          -- e.g. { commit = "o" }
  },
  keymaps = { enabled = true, prefix = "<leader>g" },
})
```

## Highlights

Every group is a default link to a standard semantic group, never a hard-coded
color, so gitvim follows your colorscheme. Define a group yourself after the
colorscheme loads and gitvim leaves it alone:

```lua
vim.api.nvim_set_hl(0, "GitVimBranch", { link = "Keyword" })
```

| Group | Default link | Used for |
|---|---|---|
| `GitVimAdded` / `Modified` / `Deleted` | `Added` / `Changed` / `Removed` | File status, signs and review |
| `GitVimRenamed` / `Copied` | `Special` | Renamed / copied files |
| `GitVimTypechange` | `Changed` | A file whose type changed |
| `GitVimUntracked` / `Ignored` | `Comment` | Untracked / ignored files |
| `GitVimConflict` | `DiagnosticWarn` | Unmerged files |
| `GitVimNormal` | `NormalFloat` | Sidebar background |
| `GitVimTitle` / `Section` / `Repo` | `Title` | Titles, section headers, repository name |
| `GitVimGroup` | `Directory` | Staged, Changes, Untracked… |
| `GitVimCount` / `Chevron` / `Icon` / `Dir` / `Hint` | `Comment` | Counts, chevrons, icons, dim directories, empty states |
| `GitVimFile` | `Normal` | File basenames |
| `GitVimBufferCurrent` | `Special` | The current buffer in BUFFERS |
| `GitVimError` | `DiagnosticError` | Inline errors |
| `GitVimSeparator` | `WinSeparator` | Separators |
| `GitVimBranch` | `Identifier` | Branch name |
| `GitVimAhead` / `Behind` | `DiagnosticInfo` / `DiagnosticWarn` | Ahead / behind counts |
| `GitVimButton` / `ButtonActive` | `Comment` / `Special` | Row buttons, an enabled button |
| `GitVimTab` / `TabSel` / `TabFill` | `TabLine` / `TabLineSel` / `TabLineFill` | Activity tabs in the winbar |
| `GitVimTabIcon` / `TabIconSel` | `TabLine` / `TabLineSel` | Tab icons |
| `GitVimLabel` | `Label` | Search field labels |
| `GitVimField` / `FieldEmpty` | `NormalFloat` / `Comment` | Search field text / placeholder |
| `GitVimToggleOn` / `ToggleOff` | `Search` / `Comment` | `[Aa]` `[ab]` `[.*]` toggles |
| `GitVimMatch` | `Search` | A search match |
| `GitVimMatchRemoved` / `Replace` | `Removed` / `Added` | Replace preview |
| `GitVimGraphNode` | `Special` | HEAD's commit node |
| `GitVimGraphSubject` / `Author` / `Date` | `Normal` / `Identifier` / `Comment` | Commit rows |
| `GitVimRefHead` / `RefLocal` / `RefRemote` / `RefTag` | `DiagnosticOk` / `Identifier` / `Constant` / `Type` | Ref badges |
| `GitVimGraphLane1` … `GitVimGraphLane8` | `Function`, `String`, `Identifier`, `Constant`, `Keyword`, `Type`, `Special`, `Number` | Lane colors |
| `GitVimHunkButton` / `ReviewLabel` | `Special` / `Title` | Review hunk buttons and pane labels |
| `GitVimBlame` | `Comment` | Current-line blame |

With `buffer.signs`, gitsigns' own groups link to these, so override the
`GitVim*` group rather than the `GitSigns*` one. Details: `:h gitvim-highlights`.

## Development

```bash
make test        # headless plenary suite (clones deps into .tests/ on first run)
make test-file FILE=tests/gitvim/fixture_spec.lua
make fmt         # stylua
make lint        # luacheck
make docs        # regenerate doc/tags
make bench       # performance gates on a generated 10k-commit repository
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
