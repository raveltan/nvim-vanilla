-- Vanilla Neovim 0.12. Native-first: vim.pack instead of a plugin manager,
-- vim.lsp.config/enable instead of mason+lspconfig glue, a hand-written
-- statusline instead of lualine/noice/fidget. Completion is the one bought-in
-- engine (blink.cmp, core/completion.lua) -- see the note there for what
-- vim.lsp.completion could not do.
--
--   n     this config                       (NVIM_APPNAME=nvim-vanilla nvim)
--   gn    this config, GAF work profile     (GAF=1 + the same)
--
-- The GAF profile adds fl-gaf's php-cs-fixer/phpcs rulesets, the api-repo
-- basedpyright paths, the Docker phpunit runner, Phabricator gx and the Angular
-- navigation + template completion (lua/gaf/angular/, shared with ~/.config/nvim).
-- The rest of the heavy pieces -- xdebug, DAP, python_nav -- stay in
-- ~/.config/nvim (`gv`).

vim.g.gaf = vim.env.GAF == "1"

require("core.options")
require("core.plugins")
require("core.keymaps")
require("core.autocmds")
require("core.lsp")
require("core.snippets").setup()
-- Tag matching works in any markup, so it loads for everyone. The Angular module
-- indexes every `selector:` under its search root, so it is GAF-only.
require("tagmatch").setup()
if vim.g.gaf then require("gaf.angular").setup() end
