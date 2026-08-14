-- Every plugin in this config. core/pack.lua does the loading, on top of the
-- builtin vim.pack.
--
-- Anything not listed is either native (core/*.lua) or deliberately gone:
-- cosmetics, terminal, undotree, obsidian, dap.

local pack = require("core.pack")
local gh = "https://github.com/"

-- ── helpers used by more than one spec ───────────────────────────────────────

-- `opts` may be a function, for pickers whose arguments depend on the buffer at
-- press time. core/pack.lua loads the plugin before invoking a key's rhs, so
-- the require here always resolves.
local function fzf(fn, opts)
  return function()
    require("fzf-lua")[fn](type(opts) == "function" and opts() or opts)
  end
end

local function here() return { cwd = vim.fn.expand("%:p:h") } end

local PROJECT_ROOTS = { "~/repo", "~/freelancer-dev" }
local function projects()
  local roots = {}
  for _, r in ipairs(PROJECT_ROOTS) do
    local p = vim.fn.expand(r)
    if vim.uv.fs_stat(p) then roots[#roots + 1] = p end
  end
  if #roots == 0 then
    vim.notify("No project roots exist (" .. table.concat(PROJECT_ROOTS, ", ") .. ")", vim.log.levels.WARN)
    return
  end
  local cmd = { "fd", "--hidden", "--no-ignore", "--type", "d", "--max-depth", "4", "^\\.git$" }
  vim.list_extend(cmd, roots)
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(res)
    local dirs = {}
    for _, line in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
      dirs[#dirs + 1] = vim.fn.fnamemodify(line:gsub("/%.git/?$", ""), ":~")
    end
    table.sort(dirs)
    require("fzf-lua").fzf_exec(dirs, {
      prompt = "Projects> ",
      actions = {
        ["default"] = function(sel)
          if not sel[1] then return end
          local dir = vim.fn.expand(sel[1])
          vim.cmd.tcd(vim.fn.fnameescape(dir))
          require("fzf-lua").files({ cwd = dir })
        end,
      },
    })
  end))
end

-- Pick a task, then run one overseer action on it. `include_ephemeral` keeps
-- one-shot shell commands in the list, which is where most of them come from.
local function task_action(action, prompt)
  return function()
    local task_list = require("overseer.task_list")
    local tasks = task_list.list_tasks({
      unique = true,
      sort = task_list.sort_finished_recently,
      include_ephemeral = true,
    })
    if #tasks == 0 then
      vim.notify("No tasks available", vim.log.levels.WARN)
      return
    end
    vim.ui.select(tasks, {
      prompt = prompt,
      kind = "overseer_task",
      format_item = function(t) return t.name end,
    }, function(task)
      if task then require("overseer.action_util").run_task_action(task, action) end
    end)
  end
end

-- ── specs ────────────────────────────────────────────────────────────────────

pack.setup({
  -- Loaded during startup so the first paint is already themed.
  {
    src = gh .. "bluz71/vim-moonfly-colors",
    name = "moonfly",
    now = true,
    config = function()
      vim.g.moonflyTransparent = true
      -- The default 1 draws VertSplit as a solid grey block that survives
      -- transparency. 2 is the line style moonfly renders with bg=NONE.
      vim.g.moonflyWinSeparator = 2
      vim.cmd.colorscheme("moonfly")
      -- Inlay hints read as annotations, not boxed text.
      vim.api.nvim_set_hl(0, "LspInlayHint", { fg = "#5c6370", italic = true })
      require("core.statusline").setup()
      require("core.todo").setup()
    end,
  },

  -- Data only. `data = true` packadd!s it without sourcing plugin/, so no Lua
  -- of it ever runs and vim.lsp.enable() just reads its lsp/<server>.lua off
  -- the rtp (core/lsp.lua). BufReadPre/BufNewFile land before FileType and the
  -- FileType entry covers `:enew` plus `:setfiletype`, and this spec registers
  -- ahead of core/lsp.lua, so the rtp is always ready first.
  {
    src = gh .. "neovim/nvim-lspconfig",
    data = true,
    event = { "BufReadPre", "BufNewFile", "FileType" },
  },
  -- Also data only, required from core/lsp.lua's before_init when a json or
  -- yaml server actually starts.
  {
    src = gh .. "b0o/SchemaStore.nvim",
    data = true,
    ft = { "json", "jsonc", "yaml" },
  },

  -- No trigger of its own. oil and fzf-lua declare it as a dep, so setup() has
  -- run before either asks MiniIcons for a glyph.
  {
    src = gh .. "echasnovski/mini.icons",
    config = function()
      require("mini.icons").setup()
      -- Some plugins still ask for nvim-web-devicons by name.
      package.preload["nvim-web-devicons"] = function()
        require("mini.icons").mock_nvim_web_devicons()
        return package.loaded["nvim-web-devicons"]
      end
    end,
  },

  -- Owns 'statuscolumn'. See the foldcolumn note in core/options.lua.
  {
    src = gh .. "mluders/comfy-line-numbers.nvim",
    event = { "BufReadPre", "BufNewFile" },
    cmd = "ComfyLineNumbers",
    config = function() require("comfy-line-numbers").setup({}) end,
  },

  -- ── search / navigation ────────────────────────────────────────────────────

  -- The entire picker layer, on the fzf C binary plus rg and fd.
  {
    src = gh .. "ibhagwan/fzf-lua",
    cmd = "FzfLua",
    deps = { "mini.icons" },
    config = function()
      require("fzf-lua").setup({
        "default",
        winopts = {
          height = 0.85,
          width = 0.85,
          border = "rounded",
          preview = { default = "builtin", layout = "flex", scrollbar = false },
        },
        -- fd over `find` because it respects .gitignore and is threaded.
        files = {
          cmd = "fd --color=never --type f --hidden --follow --exclude .git",
          formatter = "path.filename_first",
        },
        grep = {
          rg_opts = "--column --line-number --no-heading --color=always "
            .. "--smart-case --hidden --glob=!.git --max-columns=512",
        },
        previewers = {
          -- Stop treesitter from parsing a minified bundle in the preview pane.
          builtin = { syntax_limit_b = 100 * 1024 },
        },
        keymap = {
          builtin = {
            ["<C-d>"] = "preview-page-down",
            ["<C-u>"] = "preview-page-up",
            ["<C-/>"] = "toggle-help",
          },
          fzf = {
            ["ctrl-q"] = "select-all+accept", -- a multi-selection accept lands in quickfix
            ["ctrl-d"] = "preview-page-down",
            ["ctrl-u"] = "preview-page-up",
          },
        },
      })
      -- Every vim.ui.select caller, core/case.lua included, gets a fuzzy menu
      -- instead of the numbered prompt.
      require("fzf-lua").register_ui_select()
    end,
    keys = {
      { "<leader><leader>", fzf("files"), desc = "Find files" },
      { "<leader>fo", fzf("files", here), desc = "Find files (current file dir)" },
      { "<leader>fr", fzf("oldfiles"), desc = "Recent files" },
      { "<leader>fp", projects, desc = "Projects" },
      { "<leader>,", fzf("buffers"), desc = "Buffers" },
      { "<leader>fg", fzf("git_files"), desc = "Git files" },
      { "<leader>sg", fzf("live_grep_native"), desc = "Grep (workspace)" },
      { "<leader>sw", fzf("grep_cword"), desc = "Grep word" },
      { "<leader>sw", fzf("grep_visual"), mode = "x", desc = "Grep selection" },
      { "<leader>s.", fzf("live_grep_native", here), desc = "Grep in current file dir" },
      { "<leader>sb", fzf("blines"), desc = "Grep current buffer" },
      { "<leader>xx", fzf("diagnostics_document"), desc = "Buffer diagnostics" },
      { "<leader>sh", fzf("helptags"), desc = "Help pages" },
      { "<leader>sk", fzf("keymaps"), desc = "Keymaps" },
      { "<leader>sc", fzf("commands"), desc = "Commands" },
      { "<leader>sd", fzf("diagnostics_workspace"), desc = "Diagnostics" },
      { "<leader>sr", fzf("resume"), desc = "Resume last picker" },
      { "<leader>sm", fzf("marks"), desc = "Marks" },
      { "<leader>sj", fzf("jumps"), desc = "Jumplist" },
      { '<leader>s"', fzf("registers"), desc = "Registers" },
      { "<leader>s/", fzf("search_history"), desc = "Search history" },
      { "<leader>s:", fzf("command_history"), desc = "Command history" },
      { "<leader>ss", fzf("lsp_document_symbols"), desc = "Document symbols" },
      { "<leader>sS", fzf("lsp_live_workspace_symbols"), desc = "Workspace symbols" },
      { "gd", fzf("lsp_definitions"), desc = "Go to definition" },
      { "gr", fzf("lsp_references"), desc = "References" },
      { "gI", fzf("lsp_implementations"), desc = "Implementations" },
      { "gy", fzf("lsp_typedefs"), desc = "Type definitions" },
      { "<leader>gs", fzf("git_status"), desc = "Git status" },
      { "<leader>gC", fzf("git_commits"), desc = "Git log (repo)" },
    },
  },

  {
    src = gh .. "barrettruth/canola.nvim",
    deps = { "mini.icons" },
    config = function()
      require("oil").setup({
        view_options = { show_hidden = true },
        keymaps = {
          ["q"] = "actions.close",
          ["<C-h>"] = false, -- don't override window nav
          ["<C-l>"] = false,
        },
      })
    end,
    keys = {
      { "<leader>e", "<cmd>Oil<cr>", desc = "Explorer (Oil)" },
      { "-", "<cmd>Oil<cr>", desc = "Open parent directory" },
    },
  },

  -- No `event`: the plugin's own plugin/ script binds these same four keys as it
  -- sources, so the wrappers below are only ever the trigger for the first press.
  {
    src = gh .. "christoomey/vim-tmux-navigator",
    keys = {
      { "<C-h>", "<cmd>TmuxNavigateLeft<cr>", desc = "Window left" },
      { "<C-j>", "<cmd>TmuxNavigateDown<cr>", desc = "Window down" },
      { "<C-k>", "<cmd>TmuxNavigateUp<cr>", desc = "Window up" },
      { "<C-l>", "<cmd>TmuxNavigateRight<cr>", desc = "Window right" },
    },
  },

  -- ── treesitter ─────────────────────────────────────────────────────────────

  {
    src = gh .. "nvim-treesitter/nvim-treesitter",
    version = "main",
    -- BufReadPre fires before FileType, so the FileType autocmd below is
    -- registered in time to highlight that same buffer.
    event = { "BufReadPre", "BufNewFile" },
    -- :TSSync is created by config below, so it needs a trigger of its own to be
    -- reachable on a fresh machine before any file has been opened.
    cmd = "TSSync",
    config = function()
      local LANGS = {
        "angular", "bash", "blade", "css", "diff", "gitcommit", "git_rebase",
        "html", "javascript", "json", "lua", "luadoc", "markdown",
        "markdown_inline", "php", "php_only", "python", "query", "regex", "rust",
        "scss", "swift", "toml", "tsx", "typescript", "vim", "vimdoc", "yaml",
      }
      -- nvim-treesitter `main` has no ensure_installed and install() is
      -- unconditional, so handing it the full list re-downloads every parser on
      -- every session.
      local installed = {}
      for _, l in ipairs(require("nvim-treesitter.config").get_installed("parsers")) do
        installed[l] = true
      end
      local missing = vim.tbl_filter(function(l) return not installed[l] end, LANGS)
      if #missing > 0 then require("nvim-treesitter").install(missing) end

      vim.api.nvim_create_user_command("TSSync", function()
        -- Blocking, for a fresh machine or a parser ABI bump. 10 min ceiling.
        require("nvim-treesitter").install(LANGS, { force = true }):wait(600000)
        vim.notify("Treesitter parsers installed")
      end, { desc = "Install/update every parser (blocking)" })

      -- b:bigfile is the byte ceiling, set by core/autocmds.lua on BufReadPre,
      -- which always lands before FileType. Only the line count is left to check:
      -- a generated file can be short on bytes and still cost more to parse than
      -- the highlighting is worth.
      local TS_MAX_LINES = 10000
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("treesitter_highlight", { clear = true }),
        callback = function(args)
          if vim.b[args.buf].bigfile then return end
          if vim.api.nvim_buf_line_count(args.buf) > TS_MAX_LINES then return end
          pcall(vim.treesitter.start, args.buf)
          if vim.treesitter.get_parser(args.buf, nil, { error = false }) then
            vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
            -- foldlevelstart=99 in core/options.lua keeps these open on load, zc/za
            -- fold on demand. Set only where a parser exists.
            vim.wo.foldmethod = "expr"
            vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
          end
        end,
      })
    end,
  },

  -- Queries plus move/swap only. mini.ai owns af/if/ac/ic/aa/ia and consumes
  -- these same queries through gen_spec.treesitter, so mapping the select side
  -- here would shadow its counts, an/al variants and dot-repeat.
  {
    src = gh .. "nvim-treesitter/nvim-treesitter-textobjects",
    version = "main",
    event = { "BufReadPost", "BufNewFile" },
    config = function()
      require("nvim-treesitter-textobjects").setup({ select = { lookahead = true } })
      local move = require("nvim-treesitter-textobjects.move")
      local swap = require("nvim-treesitter-textobjects.swap")
      local map = vim.keymap.set

      map({ "n", "x", "o" }, "]f", function() move.goto_next_start("@function.outer", "textobjects") end, { desc = "Next function" })
      map({ "n", "x", "o" }, "[f", function() move.goto_previous_start("@function.outer", "textobjects") end, { desc = "Prev function" })
      map({ "n", "x", "o" }, "]a", function() move.goto_next_start("@parameter.outer", "textobjects") end, { desc = "Next argument" })
      map({ "n", "x", "o" }, "[a", function() move.goto_previous_start("@parameter.outer", "textobjects") end, { desc = "Prev argument" })
      map("n", "<leader>csa", function() swap.swap_next("@parameter.inner") end, { desc = "Swap with next arg" })
      map("n", "<leader>csA", function() swap.swap_previous("@parameter.inner") end, { desc = "Swap with prev arg" })

      -- Per-buffer node stack for incremental selection. <BS> reverses <CR> by
      -- one level.
      local stacks = {}

      -- Treesitter ranges are end-exclusive, visual marks are (1,0)-indexed and
      -- inclusive.
      local function select_node(node)
        local sr, sc, er, ec = node:range()
        if ec == 0 then
          if er > 0 then
            er = er - 1
            ec = #vim.api.nvim_buf_get_lines(0, er, er + 1, true)[1]
          end
          if ec == 0 then ec = 1 end
        end
        local last = vim.api.nvim_buf_line_count(0)
        vim.api.nvim_buf_set_mark(0, "<", math.min(sr + 1, last), sc, {})
        vim.api.nvim_buf_set_mark(0, ">", math.min(er + 1, last), math.max(ec - 1, 0), {})
        vim.cmd("normal! gv")
      end

      map("n", "<CR>", function()
        -- Pass <CR> through in the cmdwin (q:, q/) and special buffers where it
        -- has a real default.
        if vim.fn.win_gettype() == "command" or vim.bo.buftype ~= "" then
          return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
        end
        local node = vim.treesitter.get_node()
        if node then
          stacks[vim.api.nvim_get_current_buf()] = { node }
          select_node(node)
        end
      end, { desc = "Start incremental select" })

      map("x", "<CR>", function()
        local stack = stacks[vim.api.nvim_get_current_buf()]
        local current = stack and stack[#stack]
        local parent = current and current:parent()
        if parent then
          stack[#stack + 1] = parent
          select_node(parent)
        end
      end, { desc = "Expand selection" })

      map("x", "<BS>", function()
        local stack = stacks[vim.api.nvim_get_current_buf()]
        if stack and #stack > 1 then
          table.remove(stack)
          select_node(stack[#stack])
        end
      end, { desc = "Shrink selection" })
    end,
  },

  -- BufReadPre rather than InsertEnter. The plugin attaches from a FileType
  -- autocmd registered at setup time, so a buffer whose FileType already fired
  -- never gets it.
  {
    src = gh .. "windwp/nvim-ts-autotag",
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      -- blade is aliased upstream, typescript is ours. Angular inline
      -- `template:` backticks are an injected angular tree and the plugin's
      -- inline-template detection cannot cross the injection boundary, so
      -- without the alias it falls back to JSX patterns that never match
      -- angular's start_tag/element/end_tag nodes.
      require("nvim-ts-autotag").setup({ aliases = { ["typescript"] = "html" } })
    end,
  },

  -- ── editing ────────────────────────────────────────────────────────────────

  {
    src = gh .. "echasnovski/mini.surround",
    event = "User VeryLazy",
    config = function()
      require("mini.surround").setup({
        n_lines = 500,
        mappings = {
          add = "gsa", delete = "gsd", find = "gsf", find_left = "gsF",
          highlight = "gsh", replace = "gsr", update_n_lines = "gsn",
        },
        custom_surroundings = {
          -- Upstream's `(%w-)` tag name stops at the first hyphen, breaking
          -- gsdt/gsrt on custom elements (<fl-button>, <app-foo-bar>).
          t = { input = { "<([%w%-]-)%f[^<%w%-][^<>]->.-</%1>", "^<.->().*()</[^/]->$" } },
        },
      })
    end,
  },

  {
    src = gh .. "echasnovski/mini.ai",
    event = "User VeryLazy",
    config = function()
      local ai = require("mini.ai")
      ai.setup({
        n_lines = 500,
        custom_textobjects = {
          -- Same hyphen widening as mini.surround above, for dit/cit/dat/cat.
          t = { "<([%w%-]-)%f[^<%w%-][^<>]->.-</%1>", "^<.->().*()</[^/]->$" },
          -- Sole owner of af/if/ac/ic/aa/ia. See the nvim-treesitter-textobjects
          -- spec for why the select maps there stay unmapped.
          f = ai.gen_spec.treesitter({ a = "@function.outer", i = "@function.inner" }),
          c = ai.gen_spec.treesitter({ a = "@class.outer", i = "@class.inner" }),
          a = ai.gen_spec.treesitter({ a = "@parameter.outer", i = "@parameter.inner" }),
        },
      })
    end,
  },

  {
    src = gh .. "echasnovski/mini.pairs",
    event = "InsertEnter",
    config = function()
      require("mini.pairs").setup()
    end,
  },

  -- Pinned to a release tag, which is what lets blink fetch its prebuilt Rust
  -- matcher instead of needing cargo. See core/completion.lua.
  {
    src = gh .. "Saghen/blink.cmp",
    version = vim.version.range("1.*"),
    -- Not InsertEnter: blink installs its own insert-mode autocmds, and the one
    -- that loaded it is already being dispatched, so the first keystroke of the
    -- session would be missed. VeryLazy is after the first draw either way.
    event = "User VeryLazy",
    config = function()
      require("core.completion").setup()
    end,
  },

  -- `event` is not redundant with `keys`. Char mode hooks f/F/t/T, none of
  -- which are in the keys list, so the plugin has to be loaded before the first
  -- f press rather than on the first `s`.
  {
    src = gh .. "folke/flash.nvim",
    event = "User VeryLazy",
    config = function()
      require("flash").setup()
    end,
    keys = {
      { "s", function() require("flash").jump() end, mode = { "n", "x", "o" }, desc = "Flash" },
      { "S", function() require("flash").treesitter() end, mode = { "n", "x", "o" }, desc = "Flash Treesitter" },
      { "r", function() require("flash").remote() end, mode = "o", desc = "Remote Flash" },
      { "R", function() require("flash").treesitter_search() end, mode = { "o", "x" }, desc = "Treesitter Search" },
      { "<C-s>", function() require("flash").toggle() end, mode = "c", desc = "Toggle Flash Search" },
    },
  },

  -- Per-project indent detection (no native equivalent).
  { src = gh .. "tpope/vim-sleuth", event = { "BufReadPre", "BufNewFile" } },

  -- ── git ────────────────────────────────────────────────────────────────────

  {
    src = gh .. "lewis6991/gitsigns.nvim",
    event = { "BufReadPost", "BufNewFile" },
    config = function()
      require("gitsigns").setup({
        -- Block elements rather than Nerd Font glyphs. They render in any font
        -- and read as a continuous gutter edge, not as punctuation to decode.
        signs = {
          add = { text = "▎" }, change = { text = "▎" }, delete = { text = "▁" },
          topdelete = { text = "▔" }, changedelete = { text = "▎" }, untracked = { text = "▏" },
        },
        -- Staged hunks get a hollow bar, so `git add -p` progress is visible.
        signs_staged = {
          add = { text = "▍" }, change = { text = "▍" }, delete = { text = "▁" },
          topdelete = { text = "▔" }, changedelete = { text = "▍" },
        },
        on_attach = function(bufnr)
          local gs = require("gitsigns")
          local function map(mode, l, r, opts)
            opts = opts or {}
            opts.buffer = bufnr
            vim.keymap.set(mode, l, r, opts)
          end

          map("n", "]c", function()
            if vim.wo.diff then vim.cmd.normal({ "]c", bang = true }) else gs.nav_hunk("next") end
            vim.cmd("normal! zz")
          end, { desc = "Next hunk" })
          map("n", "[c", function()
            if vim.wo.diff then vim.cmd.normal({ "[c", bang = true }) else gs.nav_hunk("prev") end
            vim.cmd("normal! zz")
          end, { desc = "Prev hunk" })

          map("n", "<leader>gb", function() require("core.blame").blame("diff") end, { desc = "Blame line (diff)" })
          map("n", "<leader>gB", function() require("core.blame").blame("message") end, { desc = "Blame line (message)" })
          map("n", "<leader>gp", gs.preview_hunk_inline, { desc = "Preview hunk (inline)" })
          map("n", "<leader>gr", gs.reset_hunk, { desc = "Reset hunk" })
          map("v", "<leader>gr", function()
            gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
          end, { desc = "Reset selected lines" })
          map("n", "<leader>gS", gs.stage_hunk, { desc = "Stage hunk" })
          map("n", "<leader>gu", gs.undo_stage_hunk, { desc = "Undo stage hunk" })
        end,
      })
    end,
  },

  {
    src = gh .. "tpope/vim-fugitive",
    cmd = { "Git", "G", "Gclog", "Gdiffsplit", "Gedit", "Gread", "Gwrite", "Ggrep" },
    keys = {
      { "<leader>gl", function() require("core.line_history").pick() end, desc = "Line history" },
      { "<leader>gl", function()
          local s, e = vim.fn.line("v"), vim.fn.line(".")
          if s > e then s, e = e, s end
          vim.cmd("normal! \27")
          require("core.line_history").pick(s, e)
        end, mode = "v", desc = "Range history" },
      { "<leader>gf", function() require("core.line_history").file() end, desc = "File history (current file)" },
      { "<leader>gd", "<cmd>Gdiffsplit<cr>", desc = "Diff current file vs index" },
    },
  },

  -- ── database ───────────────────────────────────────────────────────────────

  -- dadbod is the query engine, dadbod-ui the drawer, dadbod-completion the
  -- table/column source blink reads in sql buffers (core/completion.lua).
  -- Connections come from connections.json under db_ui_save_location below, or
  -- from vim.g.dbs in a project-local config.
  { src = gh .. "tpope/vim-dadbod", cmd = "DB" },

  {
    src = gh .. "kristijanhusak/vim-dadbod-ui",
    cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer" },
    deps = { "vim-dadbod" },
    -- plugin/db_ui.vim bakes the drawer icons out of db_ui_use_nerd_fonts as it
    -- sources, so these have to be set before the packadd, not in config.
    init = function()
      vim.g.db_ui_auto_execute_table_helpers = 1
      -- No notification plugin in this config, so echo rather than the float.
      vim.g.db_ui_force_echo_notifications = 1
      -- Not stdpath("data"): connections and saved queries are per machine, not
      -- per config, so this shares ~/.config/nvim's store rather than starting
      -- an empty second one.
      vim.g.db_ui_save_location = vim.fn.expand("~/.local/share/nvim/db_ui")
      vim.g.db_ui_show_database_icon = 1
      vim.g.db_ui_use_nerd_fonts = 1
      vim.g.db_ui_win_position = "left"
      vim.g.db_ui_winwidth = 40
    end,
    keys = {
      { "<leader>Du", "<cmd>DBUIToggle<cr>", desc = "DB: toggle UI" },
      { "<leader>Df", "<cmd>DBUIFindBuffer<cr>", desc = "DB: find buffer" },
      { "<leader>Da", "<cmd>DBUIAddConnection<cr>", desc = "DB: add connection" },
      { "<leader>Dr", "<cmd>DBUIRenameBuffer<cr>", desc = "DB: rename buffer" },
      { "<leader>Dq", "<cmd>DBUILastQueryInfo<cr>", desc = "DB: last query info" },
    },
  },

  -- Its own spec rather than a dep of vim-dadbod: the FileType autocmd it
  -- registers calls db#connect, so dadbod has to be loaded first.
  {
    src = gh .. "kristijanhusak/vim-dadbod-completion",
    ft = { "sql", "mysql", "plsql" },
    deps = { "vim-dadbod" },
  },

  -- Editable result grids: stage cell edits like a buffer, apply as
  -- transactional SQL. Reads the same connections as dadbod and reuses DBUI
  -- result windows. In the grid: i/<CR> edit, n NULL, a apply, u undo, gf
  -- follow FK, s sort, f filter, gE export, ? help.
  {
    src = gh .. "joryeugene/dadbod-grip.nvim",
    -- No version: the repo carries stray v3.x tags that outrank the real 1.x
    -- releases, so a tag range checks out a code line missing the mysql
    -- --batch fix (upstream #11). The default branch is the real one.
    cmd = {
      "Grip", "GripStart", "GripHome", "GripConnect", "GripSchema",
      "GripTables", "GripQuery", "GripSave", "GripLoad", "GripHistory",
      "GripProfile", "GripExplain", "GripDiff", "GripCreate",
      "GripDrop", "GripRename", "GripProperties", "GripExport",
      "GripAttach", "GripDetach", "GripOpen",
    },
    keys = {
      { "<leader>Dc", "<cmd>GripConnect<cr>", desc = "DB: grip connect" },
      { "<leader>Dg", "<cmd>Grip<cr>", desc = "DB: grip grid" },
      { "<leader>Dt", "<cmd>GripTables<cr>", desc = "DB: grip tables" },
      { "<leader>Ds", "<cmd>GripSchema<cr>", desc = "DB: grip schema" },
      { "<leader>Dh", "<cmd>GripHistory<cr>", desc = "DB: grip history" },
    },
    config = function()
      require("dadbod-grip").setup({
        completion = false, -- blink + dadbod-completion already own sql buffers
        picker = "builtin", -- the zero-dep one; no snacks or telescope here
        -- :GripAsk would ship schema context to an external LLM API.
        ai = false,
      })

      -- grip parses URLs by hand and never percent-decodes the userinfo, while
      -- dadbod -- which consumes the URL grip exports to g:db -- requires it
      -- encoded, so an encoded password reaches the mysql CLI literally and
      -- fails auth. Wrapping the adapter survives plugin updates; drop this
      -- once upstream decodes.
      local mysql = require("dadbod-grip.adapters.mysql")
      local function decode_userinfo(url)
        local scheme, userinfo, rest = url:match("^(%w+://)([^@]+)(@.*)$")
        if not userinfo then return url end
        return scheme .. userinfo:gsub("%%(%x%x)", function(hex)
          return string.char(tonumber(hex, 16))
        end) .. rest
      end
      for name, fn in pairs(mysql) do
        if type(fn) == "function" then
          mysql[name] = function(...)
            local n = select("#", ...)
            local args = { ... }
            for i = 1, n do
              if type(args[i]) == "string" and args[i]:match("^mysql://") then
                args[i] = decode_userinfo(args[i])
              end
            end
            return fn(unpack(args, 1, n))
          end
        end
      end
    end,
  },

  -- Ad-hoc SQL through Redash's HTTP API. Redash is a Freelancer service, so
  -- the plugin and its result renderer are GAF-only. Local checkout, still
  -- being written -- swap `dir` for a src once it is published. The URL comes
  -- from $REDASH_URL and the key from ~/brainskey.txt, so neither is in here.
  {
    dir = "~/redash.nvim",
    name = "redash.nvim",
    enabled = vim.g.gaf,
    cmd = { "Redash", "RedashRun", "RedashSource", "RedashTables", "RedashCancel" },
    ft = "sql", -- for the buffer-local run key
    deps = { "csvview.nvim" },
    keys = {
      { "<leader>ro", "<cmd>Redash<cr>", desc = "Redash: open scratch" },
      { "<leader>rt", "<cmd>RedashTables<cr>", desc = "Redash: browse schema" },
      { "<leader>rs", "<cmd>RedashSource<cr>", desc = "Redash: data source" },
      { "<leader>rk", "<cmd>RedashCancel<cr>", desc = "Redash: cancel query" },
    },
    config = function()
      require("redash").setup({
        api_key_file = "~/brainskey.txt",
        data_source_id = 6, -- FLN-Redshift (Regular Access); :RedashSource to switch
        run_key = "<leader>rr", -- buffer-local in sql buffers
        ui = { style = "csvview" },
      })
    end,
  },

  -- Redash's result grid (ui.style="csvview"): aligned, colored columns, with
  -- delimiter-aware column motions that skip quoted commas. No trigger of its
  -- own -- redash declares it as a dep.
  {
    src = gh .. "hat0uma/csvview.nvim",
    enabled = vim.g.gaf,
    config = function()
      require("csvview").setup({
        view = { display_mode = "border" },
        keymaps = {
          jump_next_field_start = { "<Tab>", mode = { "n", "v" } },
          jump_prev_field_start = { "<S-Tab>", mode = { "n", "v" } },
          textobject_field_inner = { "if", mode = { "o", "x" } },
          textobject_field_outer = { "af", mode = { "o", "x" } },
        },
      })
    end,
  },

  -- ── format / lint ──────────────────────────────────────────────────────────

  {
    src = gh .. "stevearc/conform.nvim",
    event = "BufWritePre",
    -- FormatDisable/FormatEnable are created by config below, so they need their
    -- own trigger to work before the session's first save.
    cmd = { "ConformInfo", "FormatDisable", "FormatEnable" },
    keys = {
      { "<leader>cf", function() require("conform").format({ async = true }) end,
        mode = { "n", "v" }, desc = "Format file / selection" },
    },
    config = function()
      -- A globally installed formatter must not restyle a repo that never opted
      -- in. pint reformatting a non-Laravel PHP checkout is the case that bites.
      local function rooted_at(marker)
        return function(_, ctx)
          return #vim.fs.find({ marker }, { path = ctx.dirname, upward = true }) > 0
        end
      end

      -- php/blade come from whichever profile is active. GAF uses fl-gaf's own
      -- php-cs-fixer build, everything else resolves pint/blade-formatter per
      -- buffer. Both are condition-guarded, so a PHP file belonging to neither
      -- falls through to `lsp_format = "fallback"` below.
      local php = vim.g.gaf
        and {
          by_ft = { php = { "php_cs_fixer" } },
          formatters = { php_cs_fixer = require("gaf.formatting").php_cs_fixer_formatter() },
        }
        or {
          by_ft = require("artisan").formatters_by_ft(),
          formatters = require("artisan").formatters(),
        }

      require("conform").setup({
        formatters_by_ft = {
          javascript = { "prettierd", "prettier", stop_after_first = true },
          typescript = { "prettierd", "prettier", stop_after_first = true },
          javascriptreact = { "prettierd", "prettier", stop_after_first = true },
          typescriptreact = { "prettierd", "prettier", stop_after_first = true },
          -- stylelint comes first because some projects format scss with
          -- `stylelint --fix` and their prettier only covers *.ts. conform
          -- resolves it from node_modules and skips it where absent.
          scss = { "stylelint", "prettierd", "prettier", stop_after_first = true },
          css = { "stylelint", "prettierd", "prettier", stop_after_first = true },
          -- html LSP has provideFormatter = false, so conform owns html.
          html = { "prettierd", "prettier", stop_after_first = true },
          json = { "prettierd", "prettier", stop_after_first = true },
          yaml = { "prettierd", "prettier", stop_after_first = true },
          markdown = { "prettierd", "prettier", stop_after_first = true },
          python = { "ruff_organize_imports", "ruff_format" },
          rust = { "rustfmt" },
          swift = { "swiftformat" },
          lua = { "stylua" },
          php = php.by_ft.php,
          blade = php.by_ft.blade,
        },
        formatters = vim.tbl_extend("error", php.formatters, {
          -- This config's Lua is hand-formatted at 2 spaces and stylua's
          -- defaults clobber it, so it runs only where a project opts in with
          -- its own stylua config.
          stylua = { condition = rooted_at(".stylua.toml") },
        }),
        format_on_save = function(bufnr)
          if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then return end
          -- php-cs-fixer cold starts overrun the 500ms default. The lsp fallback
          -- covers filetypes with no conform entry.
          return { timeout_ms = 3000, lsp_format = "fallback" }
        end,
      })

      vim.api.nvim_create_user_command("FormatDisable", function(a)
        if a.bang then vim.b.disable_autoformat = true else vim.g.disable_autoformat = true end
      end, { bang = true, desc = "Disable format-on-save (! = buffer only)" })
      vim.api.nvim_create_user_command("FormatEnable", function()
        vim.b.disable_autoformat, vim.g.disable_autoformat = false, false
      end, { desc = "Re-enable format-on-save" })
    end,
  },

  -- Nothing here runs before a save, so BufWritePost is both the load trigger and
  -- the work trigger. The buffer that loaded it is linted by hand below, because
  -- an autocmd registered mid-dispatch does not fire for that same write.
  {
    src = gh .. "mfussenegger/nvim-lint",
    event = "BufWritePost",
    -- artisan.setup() below is what creates :LaravelPhpstan, and it is a
    -- whole-project run nobody has to save first to want.
    cmd = not vim.g.gaf and "LaravelPhpstan" or nil,
    config = function()
      local lint = require("lint")
      lint.linters_by_ft = {}
      if vim.fn.executable("swiftlint") == 1 then
        lint.linters_by_ft.swift = { "swiftlint" }
      end

      if vim.g.gaf then
        local paths = require("gaf.paths")
        local fmt = require("gaf.formatting")
        local phpcs = lint.linters.phpcs
        -- Both rulesets set `installed_paths` to cwd-relative vendor paths, so
        -- phpcs run from anywhere else exits with `Referenced sniff ... does not
        -- exist` as plain text on stdout, which then blows up the JSON parser.
        phpcs.cmd = paths.fl_gaf .. "/vendor/bin/phpcs"
        phpcs.cwd = paths.fl_gaf
        phpcs.args = fmt.phpcs_args()
        -- Re-grade through .arclint's per-sniff severity map so the buffer
        -- agrees with `arc lint` about what actually blocks.
        phpcs.parser = fmt.phpcs_parser(phpcs.parser)
        lint.linters_by_ft.php = { "phpcs" }
      else
        require("artisan").configure_lint(lint)
        require("artisan").setup()
      end

      local function lint_buf(buf)
        if vim.bo[buf].filetype ~= "php" then
          lint.try_lint()
          return
        end
        if vim.g.gaf then
          -- .arclint excludes some PHP from phpcs entirely. support/flarc is
          -- PHP 7.4 and would fail the 8.1 compatibility sniffs, and the
          -- phpstan baselines are excluded repo-wide. nvim-lint has no
          -- per-linter condition, so the exclusion belongs here.
          local relpath = require("gaf.paths").gaf_relpath(buf)
          if require("gaf.arclint").phpcs_applies(relpath) then lint.try_lint() end
          return
        end
        -- Eligibility is per project, an artisan root plus a phpstan binary and
        -- config, while linters_by_ft is global, so php is dispatched per buffer.
        local names = require("artisan").php_linters(buf)
        if #names > 0 then lint.try_lint(names) end
      end

      vim.api.nvim_create_autocmd("BufWritePost", {
        group = vim.api.nvim_create_augroup("lint", { clear = true }),
        callback = function(args) lint_buf(args.buf) end,
      })
      lint_buf(vim.api.nvim_get_current_buf())
    end,
  },

  -- vim API + plugin types when editing this config.
  {
    src = gh .. "folke/lazydev.nvim",
    ft = "lua",
    config = function()
      require("lazydev").setup({
        library = { { path = "${3rd}/luv/library", words = { "vim%.uv" } } },
      })
    end,
  },

  -- ── tests ──────────────────────────────────────────────────────────────────
  -- No triggers of their own. neotest declares them as `deps` and the keymaps
  -- that pull neotest in live in core/autocmds.lua, so nothing here touches the
  -- rtp until the first <leader>t* press.

  { src = gh .. "nvim-lua/plenary.nvim" },
  { src = gh .. "nvim-neotest/nvim-nio" },
  { src = gh .. "olimorris/neotest-phpunit" },
  { src = gh .. "marilari88/neotest-vitest" },
  { src = gh .. "nvim-neotest/neotest-python" },
  {
    src = gh .. "nvim-neotest/neotest",
    deps = {
      "plenary.nvim", "nvim-nio",
      "neotest-phpunit", "neotest-vitest", "neotest-python",
    },
    config = function()
      -- Under GAF, phpunit runs through scripts/neotest-run-tests.sh, which
      -- wraps bin/run-tests so Docker namespacing, setup and teardown stay with
      -- the upstream tool. Infra has to be up first, via <leader>tx.
      local phpunit = vim.g.gaf
        and require("neotest-phpunit")({
          phpunit_cmd = vim.fn.stdpath("config") .. "/scripts/neotest-run-tests.sh",
        })
        or require("neotest-phpunit")

      require("neotest").setup({
        adapters = {
          phpunit,
          require("neotest-vitest")({
            -- ui-tests/ are Playwright specs driven by their own runner.
            is_test_file = function(path)
              if path:match("ui%-tests/src/.+%.spec%.ts$") then return false end
              return path:match("%.test%.[mc]?[jt]sx?$") ~= nil
                or path:match("%.spec%.[mc]?[jt]sx?$") ~= nil
            end,
            filter_dir = function(name) return name ~= "node_modules" and name ~= "ui-tests" end,
          }),
          require("neotest-python")({ dap = { justMyCode = false } }),
        },
        -- With discovery on, the first run in a monorepo recursively walks the
        -- whole tree looking for test files.
        discovery = { enabled = false },
        -- This config renders no virtual text anywhere, and a failed assertion
        -- already shows in the output panel and the summary.
        diagnostic = { enabled = false },
        output = { open_on_run = false },
        quickfix = { enabled = false },
      })
    end,
  },

  -- ── tasks ──────────────────────────────────────────────────────────────────

  {
    src = gh .. "stevearc/overseer.nvim",
    cmd = { "OverseerRun", "OverseerShell", "OverseerToggle", "OverseerTaskAction", "OverseerOpen", "OverseerClose" },
    keys = {
      { "<leader>or", "<cmd>OverseerRun<cr>", desc = "Run task" },
      { "<leader>oc", "<cmd>OverseerShell<cr>", desc = "Run shell command" },
      { "<leader>ol", task_action("open float", "Open task (float)"), desc = "Open task in float" },
      { "<leader>oh", task_action("open hsplit", "Open task (hsplit)"), desc = "Open task in hsplit" },
      { "<leader>ov", task_action("open vsplit", "Open task (vsplit)"), desc = "Open task in vsplit" },
      { "<leader>od", task_action("dispose", "Dispose task"), desc = "Dispose task" },
    },
    config = function()
      require("overseer").setup({
        -- overseer/template/user/ is the GAF Playwright runner. Its condition
        -- already rejects a non-webapp cwd; disabling the module outside GAF keeps
        -- `<leader>or` from require()ing gaf/ modules at all elsewhere.
        disable_template_modules = vim.g.gaf and {} or { "^overseer%.template%.user%." },
        task_list = {
          direction = "bottom",
          min_height = 8,
          max_height = { 20, 0.2 },
          -- Default <CR> opens output in the task list's own split, which is 8
          -- lines tall. Float instead, same as the pickers above.
          keymaps = {
            ["<CR>"] = { "keymap.open", opts = { dir = "float" }, desc = "Open task output in float" },
            ["o"] = { "keymap.open", opts = { dir = "float" }, desc = "Open task output in float" },
          },
        },
        component_aliases = {
          default = {
            { "open_output", on_start = "always", direction = "float", focus = true },
            "on_exit_set_status",
            "on_complete_notify",
            -- Finished tasks stay in the list until viewed once, then clear
            -- themselves, so the list is only what still needs attention.
            { "on_complete_dispose", require_view = { "SUCCESS", "FAILURE" } },
          },
        },
      })
    end,
  },

  {
    src = gh .. "folke/which-key.nvim",
    event = "User VeryLazy",
    config = function()
      local spec = {
        { "<leader>b", group = "buffer" },
        { "<leader>c", group = "code" },
        { "<leader>cs", group = "swap" },
        { "<leader>D", group = "database" },
        { "<leader>f", group = "find/files" },
        { "<leader>g", group = "git" },
        { "<leader>h", group = "harpoon" },
        { "<leader>o", group = "overseer" },
        { "<leader>s", group = "search" },
        { "<leader>t", group = "test" },
        { "<leader>u", group = "ui" },
        { "<leader>x", group = "diagnostics/quickfix" },
        { "g", group = "goto" },
        { "gs", group = "surround" },
      }
      if vim.g.gaf then
        spec[#spec + 1] = { "<leader>r", group = "redash" }
      end
      require("which-key").setup({
        -- "modern" is a floating rounded box at the bottom, against the legacy
        -- full-width bar glued to the cmdline.
        preset = "modern",
        spec = spec,
      })
    end,
  },
})

-- fzf-lua only loads off a picker key or :FzfLua, so its register_ui_select()
-- has not run yet the first time something calls vim.ui.select -- code actions,
-- core/case.lua, the overseer task pickers -- and that call would get the
-- builtin numbered prompt. Pull fzf-lua in on demand instead: register_ui_select
-- overwrites vim.ui.select during config, so after the load the global is the
-- fuzzy one and this shim hands the arguments straight to it.
do
  local builtin = vim.ui.select
  local shim
  shim = function(items, opts, on_choice)
    pack.load("fzf-lua")
    local impl = vim.ui.select ~= shim and vim.ui.select or builtin
    return impl(items, opts, on_choice)
  end
  vim.ui.select = shim
end
