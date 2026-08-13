# nvim-vanilla

Native-first Neovim 0.12. **30 plugins** (24 direct + neotest's six-piece stack),
**8,400 lines** of Lua, no plugin manager. About 5,500 of those lines are ported
carry-overs (`gaf/` 4,020, `tagmatch` 310, `artisan` 370, and the
`rename`/`scss`/`blame`/`line_history`/`wordsearch`/`foldtext` helpers 830) rather
than new config. The config itself is the remaining ~2,900.

Startup is about 0.7x the 102-plugin config it replaces, 16.4ms against 23.9ms
measured back to back. Absolute figures move with machine load, so compare the
two in the same run rather than trusting either number alone.

Statusline redraw 2.7µs. First press of the heaviest lazy key (`<leader>tr`,
which pulls neotest and 4 adapters) is 8.3ms, half a frame.

```sh
n     # this config                    (NVIM_APPNAME=nvim-vanilla nvim)
gn    # this config, GAF work profile  (GAF=1 + the same)
gv    # the full ~/.config/nvim, GAF    (everything below that vanilla drops)
```

## GAF profile (`gn`)

`vim.g.gaf` gates `lua/gaf/`, ~4000 lines (3600 of them the Angular module):

| | |
|---|---|
| php format | fl-gaf's own php-cs-fixer, with the src2 ruleset picked per file |
| php lint | `vendor/bin/phpcs`, ruleset and per-sniff severities read from `.arclint` so the buffer agrees with `arc lint`. `support/flarc/` and the phpstan baselines excluded |
| python | basedpyright with the api-repo's 11 import roots, the api311 pyenv interpreter, and the thrift-stub severity overrides |
| typescript | vtsls `importModuleSpecifier = project-relative` (satisfies both halves of `validate-freelancer-imports`) |
| tests | phpunit through `scripts/neotest-run-tests.sh` (bin/run-tests + Docker). `<leader>tx` / `<leader>tX` bring the infra up and down |
| angular | selector navigation (`gd` on tags/attrs/classes/routes, `<leader>c{p,G,R}`) and inline-template completion — component tags, `@Input`/`@Output`, enum values, auto-import. Served as a blink.cmp source (`lua/gaf/angular/inputs_source.lua`), merged with vtsls in the same menu |
| `gx` | opens `D12345` / `T12345` in Phabricator |
| servers | tailwindcss dropped, it never starts in the monolith |

Not ported, still `gv`-only: xdebug driver, DAP, python_nav, thrift typing
helpers, UI-test adapter, neocursor.

## Laravel (non-GAF, `n`)

`lua/artisan.lua` resolves the project from each **buffer's** path, so several
Laravel checkouts can be open at once and none need be. Everything is guarded on
the project actually shipping the tool, so a globally installed `pint` never
reformats an unrelated PHP repo and a plain PHP file falls through to
`lsp_format = "fallback"`.

- format: `pint` → `php_cs_fixer`, `blade-formatter` for views, each with `cwd`
  set to the Laravel root so `pint.json` / `.bladeformatterrc` resolve
- lint: phpstan/larastan on save, plus `:LaravelPhpstan [level]` for a
  whole-project run into the quickfix list

It is named `artisan`, not `laravel`, because a module under `lua/` shadows any
plugin of the same name.

## What is native here

| replaced | native mechanism |
|---|---|
| lazy.nvim | `vim.pack` + `lua/core/pack.lua` |
| mason, mason-lspconfig, mason-tool-installer | `vim.lsp.config` / `vim.lsp.enable`, binaries from brew/npm/pipx |
| LuaSnip, friendly-snippets | `vim.snippet` + `lua/core/snippets.lua` (JSON packs in `snippets/`, served to the menu by `lua/core/snippet_source.lua`; the `laravel/` and `pest/` overlays are gated on the buffer's project, not on the profile, because packs are read per buffer instead of into a global registry) |
| lualine, noice, fidget, harpoon-lualine | `lua/core/statusline.lua` (`vim.lsp.status()` for progress) |
| snacks.nvim | fzf-lua for pickers, `lua/core/toggle.lua` for the toggle registry, bigfile/prose autocmds |
| trouble, quicker | quickfix + `vim.diagnostic.setqflist()` + `:cdo` |
| nvim-lightbulb, actions-preview | `vim.lsp.buf.code_action()` |
| vim-matchup | builtin matchit / matchparen |
| ts-comments | builtin `gc` + `after/ftplugin/*` commentstring |
| nvim-hlslens | builtin search count, 0.12's default `shortmess` has no `S` |
| harpoon | `lua/core/harpoon.lua` |
| grug-far | `:grep` (rg) + `:cdo` on `<leader>xr` |
| todo-comments | `lua/core/todo.lua` |
| text-case | `lua/core/case.lua` |
| dial, marks, undotree, yanky, mini.bufremove, edgy | builtin `<C-a>`/`<C-x>`, marks, `undofile`, registers, `:bd`, `wincmd` |

`nvim-lspconfig` is installed but never loaded as a plugin. `data = true` puts it
on the runtimepath so `vim.lsp.enable()` can read its `lsp/*.lua` server
definitions, and its `plugin/` script is never sourced.

## Layout

```
init.lua               entry point
lua/core/pack.lua      deferred loading over vim.pack
lua/core/plugins.lua   every plugin spec
lua/core/options.lua   options
lua/core/keymaps.lua   global keymaps
lua/core/autocmds.lua  autocmds
lua/core/lsp.lua       server config, diagnostics, attach
lua/core/statusline.lua
lua/core/{toggle,harpoon,todo,case,snippets}.lua   native plugin replacements
lua/core/{rename,scss,blame,line_history,wordsearch,foldtext}.lua   ported helpers
lua/tagmatch/          treesitter tag matching (%, i%/a%, tag rename)
lua/gaf/angular/       Angular navigation + template completion (GAF only)
lua/overseer/template/user/   GAF Playwright UI-test tasks for `<leader>or`
after/ftplugin/        blade commentstring, markdown gf
after/queries/blade/   indent fixes upstream lacks
snippets/*.json        VS Code-format snippet packs (filename = filetype)
snippets/{laravel,pest}/   overlay packs, added only in a matching project
```

## Commands

| command | does |
|---|---|
| `:PackStatus` | install + load state of every plugin |
| `:PackInstall` | clone anything missing, in parallel |
| `:PackLoad [name]` | load a deferred plugin now (no arg = all) |
| `:PackUpdate` | load everything, then `vim.pack.update()` |
| `:PackClean` | delete plugins no longer in the spec list |
| `:TSSync` | install/update every treesitter parser, blocking |
| `:LspServers` | which servers are on `$PATH` |
| `:SnippetsEdit [laravel\|pest]` | edit this filetype's snippet pack, or one of its overlay packs |
| `:SnippetsReload` | drop the snippet caches and re-read `snippets/` |
| `:FormatDisable[!]` / `:FormatEnable` | turn format-on-save off / on (`!` = buffer only) |
| `:Todo[!]` | TODO comments → quickfix (`!` = this buffer) |
| `:LaravelPhpstan [level]` | whole-project phpstan → quickfix |
| `:ComfyLineNumbers enable\|disable\|toggle` | the number-column plugin's own switch |

## Completion

blink.cmp, autotriggering on keyword characters. `<CR>` accepts, `<C-n>`/`<C-p>`
move. `<Tab>`/`<S-Tab>` jump snippet placeholders and are literal tabs otherwise.

## Installing the tools

Servers and CLI tools come from the system, never from mason:

```sh
npm install -g @vtsls/language-server vscode-langservers-extracted \
  yaml-language-server @tailwindcss/language-server \
  @olrtg/emmet-language-server prettier
brew install lua-language-server typos-lsp phpantom-lsp stylua fzf ripgrep fd lazygit
pipx install basedpyright ruff
rustup component add rust-analyzer
```

`:LspServers` shows what is still missing.

## Not here, on purpose

Cosmetics (noice, satellite, hlargs, rainbow-delimiters, colorizer,
treesitter-context, dashboard), terminal toggle, undotree, obsidian, DAP,
dadbod, devdocs, kulala, flutter, xcodebuild, laravel.nvim, and
anything Ruby. Those stay in `~/.config/nvim`, reachable with `gv`.
