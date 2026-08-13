local autocmd = vim.api.nvim_create_autocmd
local augroup = vim.api.nvim_create_augroup

autocmd("TextYankPost", {
  group = augroup("highlight_yank", { clear = true }),
  callback = function() vim.hl.on_yank() end,
})

-- Replaces clipboard=unnamedplus. macOS has no cached pbcopy/pbpaste provider, so
-- unnamedplus spawns a synchronous process per delete/change/put, measured at
-- ~912ms for 100@q of dd against 0.4ms without it.
autocmd("TextYankPost", {
  group = augroup("yank_to_clipboard", { clear = true }),
  callback = function()
    if vim.v.event.operator == "y" and vim.v.event.regname == "" then
      vim.fn.setreg("+", vim.fn.getreg('"'), vim.fn.getregtype('"'))
    end
  end,
})

autocmd("VimResized", {
  group = augroup("resize_splits", { clear = true }),
  callback = function()
    local current_tab = vim.fn.tabpagenr()
    vim.cmd("tabdo wincmd =")
    vim.cmd("tabnext " .. current_tab)
  end,
})

autocmd("BufWritePre", {
  group = augroup("auto_create_dir", { clear = true }),
  callback = function(event)
    if event.match:match("^%w%w+:[\\/][\\/]") then return end
    local file = vim.uv.fs_realpath(event.match) or event.match
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":p:h"), "p")
  end,
})

autocmd("BufReadPost", {
  group = augroup("last_cursor_position", { clear = true }),
  callback = function(event)
    -- gitcommit/gitrebase carry a stale `"` mark from the previous commit.
    local ft = vim.bo[event.buf].filetype
    if vim.bo[event.buf].buftype ~= "" or ft == "gitcommit" or ft == "gitrebase" then return end
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(0) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Runs after the runtime ftplugins that shadow the global [[/]] maps in
-- core/keymaps.lua, so re-asserting them buffer-locally wins everywhere.
autocmd("FileType", {
  group = augroup("universal_word_search", { clear = true }),
  callback = function(ev)
    -- Scheduled because :help buffers get their buftype set after FileType fires,
    -- and qf/help/terminal/prompt keep their own [[ ]].
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(ev.buf) or vim.bo[ev.buf].buftype ~= "" then return end
      local search_cword = require("core.wordsearch").search_cword
      vim.keymap.set("n", "]]", function() search_cword("n") end,
        { buffer = ev.buf, desc = "Next occurrence of word (text search)" })
      vim.keymap.set("n", "[[", function() search_cword("N") end,
        { buffer = ev.buf, desc = "Prev occurrence of word (text search)" })
    end)
  end,
})

-- One highlighted row on screen rather than one per split, because on a
-- transparent background nothing else marks which window holds the cursor. The
-- flag is only ever set on leave, so a window that never had cursorline (pickers,
-- terminals) is not handed one on entry.
local auto_cursorline = augroup("auto_cursorline", { clear = true })
autocmd("WinLeave", {
  group = auto_cursorline,
  callback = function()
    if vim.wo.cursorline then
      vim.w.auto_cursorline = true
      vim.wo.cursorline = false
    end
  end,
})
autocmd("WinEnter", {
  group = auto_cursorline,
  callback = function()
    if vim.w.auto_cursorline then
      vim.wo.cursorline = true
      vim.w.auto_cursorline = nil
    end
  end,
})

autocmd("FileType", {
  group = augroup("close_with_q", { clear = true }),
  pattern = { "help", "qf", "man", "checkhealth", "gitsigns-blame", "fugitive", "git" },
  callback = function(event)
    vim.bo[event.buf].buflisted = false
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = event.buf, silent = true })
  end,
})

-- Registered here rather than in the neotest spec so that opening a test-language
-- file does not drag in neotest and every adapter (~68ms measured in the previous
-- config).
autocmd("FileType", {
  group = augroup("neotest_keys", { clear = true }),
  pattern = { "php", "typescript", "javascript", "python" },
  callback = function(ev)
    local o = { buffer = ev.buf, silent = true }
    local function nt()
      require("core.pack").load("neotest")
      return require("neotest")
    end
    local function tmap(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", o, { desc = desc }))
    end
    tmap("<leader>tr", function() nt().run.run() end, "Run nearest test")
    tmap("<leader>tf", function() nt().run.run(vim.fn.expand("%")) end, "Run file tests")
    tmap("<leader>tl", function() nt().run.run_last() end, "Run last test")
    tmap("<leader>ts", function() nt().summary.toggle() end, "Test summary")
    tmap("<leader>to", function() nt().output.open({ enter = true, auto_close = true }) end, "Test output")
    tmap("<leader>tO", function() nt().output_panel.toggle() end, "Test output panel")
    tmap("<leader>tS", function() nt().run.stop() end, "Stop test run")
    tmap("]n", function() nt().jump.next({ status = "failed" }) end, "Next failed test")
    tmap("[n", function() nt().jump.prev({ status = "failed" }) end, "Prev failed test")

    -- The GAF phpunit runner talks to Docker infra that must be brought up
    -- explicitly, or bin/run-tests bails with "Services are not running".
    if vim.g.gaf and ev.match == "php" then
      local infra = require("gaf.test_infra")
      tmap("<leader>tx", infra.setup_infra, "Setup test infra")
      tmap("<leader>tX", infra.shutdown_infra, "Shutdown test infra")
      tmap("<leader>tD", infra.toggle_debug_flag, "Toggle GAF_DEBUG (xdebug in test container)")
    end
  end,
})

-- options.lua strips "t" from formatoptions globally to stop code lines wrapping
-- mid-typing, and prose is where that behaviour is actually wanted.
autocmd("FileType", {
  group = augroup("prose", { clear = true }),
  pattern = { "markdown", "gitcommit", "text" },
  callback = function(ev)
    vim.opt_local.formatoptions:append("t")
    vim.opt_local.textwidth = ev.match == "gitcommit" and 72 or 100
    vim.opt_local.spell = true
  end,
})

autocmd("BufReadPre", {
  group = augroup("bigfile", { clear = true }),
  callback = function(ev)
    local ok, stat = pcall(vim.uv.fs_stat, vim.api.nvim_buf_get_name(ev.buf))
    if not ok or not stat or stat.size < 500 * 1024 then return end
    vim.b[ev.buf].bigfile = true
    vim.bo[ev.buf].swapfile = false
    vim.bo[ev.buf].undofile = false
    -- Scheduled: the window options below need a window, and BufReadPre runs
    -- before the buffer is displayed.
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(ev.buf) then return end
      vim.bo[ev.buf].syntax = ""
      vim.wo.foldmethod = "manual"
      vim.wo.list = false
      vim.wo.wrap = false
    end)
  end,
})
