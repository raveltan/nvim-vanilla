vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local opt = vim.opt

opt.number = true
opt.relativenumber = true
opt.termguicolors = true
opt.showtabline = 0
-- yes:2, not yes: the gutter hosts gitsigns hunk bars alongside marks, and at
-- width 1 the highest-priority sign silently hides the rest.
opt.signcolumn = "yes:2"
opt.shiftwidth = 2
opt.tabstop = 2
opt.expandtab = true
-- No smartindent: it is C-style, ignored wherever indentexpr is set, and it
-- forces `#` comments to column 0.
opt.breakindent = true
opt.splitbelow = true
opt.splitright = true
opt.updatetime = 500
opt.cursorline = true
-- The row highlight alone is nearly invisible on a transparent background.
opt.cursorlineopt = "number,line"
-- The default guicursor has no blink at all, and a slow one makes the caret
-- findable after a picker or float closes without the strobe of a fast one.
opt.guicursor = table.concat({
  "n-v-c-sm:block",
  "i-ci-ve:ver25",
  "r-cr-o:hor20",
  "a:blinkwait700-blinkoff400-blinkon250",
}, ",")
opt.scrolloff = 8
-- undofile is keyed to the file's content hash, so a checkout, branch switch or
-- external rewrite still drops history. g-/g+ and :earlier reach orphaned branches.
opt.undofile = true
opt.undolevels = 10000
opt.ignorecase = true
opt.smartcase = true
opt.mouse = "a"
opt.winborder = "rounded"
-- 'winborder' covers floats only, so without this the builtin popup menu stays
-- square. pumblend stays 0 because a blended pum shows buffer text through it.
opt.pumborder = "rounded"
opt.laststatus = 3
-- Pending keys land on the last cmdline row by default, where they are easy to
-- miss. core/statusline.lua draws them via %S.
opt.showcmdloc = "statusline"
opt.smoothscroll = true
-- diff:╱ makes deleted-block filler rows read as absence rather than as content.
-- No foldopen/foldclose: 'foldcolumn' is 0, so nothing would draw them.
opt.fillchars = { eob = " ", fold = " ", diff = "╱", foldsep = "│" }

opt.foldlevelstart = 99
-- vim.treesitter.foldtext() does not exist in 0.12.
opt.foldtext = "v:lua.require'core.foldtext'.foldtext()"
-- linematch:40 is a 0.12 default, so appending 60 without removing it first
-- leaves both in the option string.
opt.diffopt:remove("linematch:40")
opt.diffopt:append("vertical")
opt.diffopt:append("algorithm:histogram")
opt.diffopt:append("linematch:60")
opt.list = true
opt.listchars = { tab = "▸ ", trail = "·", nbsp = "␣", extends = "❯", precedes = "❮" }

opt.virtualedit = "block"
opt.pumheight = 10
-- 'pumwidth' is only a minimum, so without a maximum one long label stretches
-- the menu to the window edge.
opt.pummaxwidth = 80
-- blink.cmp draws its own menu, so this governs builtin ins-completion only.
opt.completeopt = { "menu", "menuone", "noselect", "popup", "fuzzy" }

-- Semantic tokens default to 125 against treesitter's 100, so @lsp.type.*
-- overpaints every capture it overlaps and an LSP-attached buffer looks flatter
-- than the same file with the server stopped (neovim/neovim#33614, open, no
-- per-language knob).
vim.hl.priorities.semantic_tokens = 95
opt.confirm = true
opt.inccommand = "split"
opt.jumpoptions = "stack,view,clean"
opt.shortmess:append("I")
-- "t" auto-hard-wraps code, not just comments, inserting surprise newlines while
-- typing a long line. Prose filetypes re-add it (core/autocmds.lua).
opt.textwidth = 150
-- "+1" tracks 'textwidth' per buffer, so prose gets its own edge instead of a
-- second bar drawn through every code file.
opt.colorcolumn = "+1"
opt.formatoptions:remove("t")

-- 0.12 already defaults grepprg to rg, but without these flags. 'grepformat' is
-- correct out of the box, so it is not repeated here.
if vim.fn.executable("rg") == 1 then
  opt.grepprg = "rg --vimgrep --smart-case --hidden --glob=!.git"
end

-- No remote-plugin hosts in use, so this skips provider probing and the
-- checkhealth noise.
vim.g.loaded_node_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0

-- matchit and matchparen are absent on purpose, being what replaced the removed
-- vim-matchup. These are guard variables rather than plugin names, so tutor.vim
-- appears as loaded_tutor_mode_plugin.
for _, g in ipairs({
  "loaded_gzip", "loaded_tarPlugin", "loaded_tutor_mode_plugin",
  "loaded_zipPlugin", "loaded_netrwPlugin",
}) do
  vim.g[g] = 1
end
