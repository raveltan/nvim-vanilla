-- Plugin-owned keys (fzf-lua pickers, oil, fugitive, gitsigns, neotest) live next
-- to their spec in core/plugins.lua and core/autocmds.lua, so pressing one is what
-- loads the plugin.

local map = vim.keymap.set

map("n", "<leader>|", "<cmd>vsplit<cr>", { desc = "Vertical split" })
map("n", "<leader>-", "<cmd>split<cr>", { desc = "Horizontal split" })

map("n", "<A-j>", "<cmd>m .+1<cr>==", { desc = "Move line down" })
map("n", "<A-k>", "<cmd>m .-2<cr>==", { desc = "Move line up" })
map("v", "<A-j>", ":m '>+1<cr>gv=gv", { desc = "Move selection down" })
map("v", "<A-k>", ":m '<-2<cr>gv=gv", { desc = "Move selection up" })

map("n", "<leader>bd", "<cmd>bdelete<cr>", { desc = "Delete buffer" })
map("n", "<leader>bD", "<cmd>bdelete!<cr>", { desc = "Delete buffer (force)" })
map("n", "<leader>bo", "<cmd>%bd|e#|bd#<cr>", { desc = "Close other buffers" })
map("n", "[b", "<cmd>bprevious<cr>", { desc = "Prev buffer" })
map("n", "]b", "<cmd>bnext<cr>", { desc = "Next buffer" })

map("n", "<esc>", "<cmd>noh<cr><esc>", { desc = "Clear highlights" })

-- ── LSP ───────────────────────────────────────────────────────────────────────

-- 0.12's default LSP maps sit under `gr`, which this config binds to references,
-- so every `gr` press waited out 'timeoutlen' (1000ms) for a second key. Each also
-- duplicates a binding here (gra=<leader>ca, gri=gI, grr=gr, grt=gy, gO=<leader>ss),
-- grn is raw vim.lsp.buf.rename that bypasses core/rename.lua's class/tag/PHP-$
-- handling, and grx runs codelens, which is never enabled here.
for _, lhs in ipairs({ "gra", "gri", "grn", "grr", "grt", "grx", "gO" }) do
  pcall(vim.keymap.del, "n", lhs)
end
pcall(vim.keymap.del, "v", "gra")
pcall(vim.keymap.del, "x", "gra")

-- Wrapped rather than referenced bare, because naming vim.lsp.buf here forces
-- require('vim.lsp.buf') during startup (measured 0.5ms).
map({ "n", "v" }, "<leader>ca", function() vim.lsp.buf.code_action() end, { desc = "Code action" })
map("n", "<leader>cA", function()
  vim.lsp.buf.code_action({ context = { only = { "source" }, diagnostics = {} } })
end, { desc = "Source action" })
map("n", "<leader>cr", function() require("core.rename").rename() end, { desc = "Rename symbol" })
map("n", "K", function() vim.lsp.buf.hover() end, { desc = "Hover docs" })
map("n", "gK", function() vim.lsp.buf.signature_help() end, { desc = "Signature help" })
map("n", "<leader>cd", vim.diagnostic.open_float, { desc = "Line diagnostics" })
map("n", "[d", function() vim.diagnostic.jump({ count = -1 }) end, { desc = "Prev diagnostic" })
map("n", "]d", function() vim.diagnostic.jump({ count = 1 }) end, { desc = "Next diagnostic" })

-- ── quickfix ──────────────────────────────────────────────────────────────────

local function qf_jump(forward)
  if not pcall(vim.cmd, forward and "cnext" or "cprev") then
    pcall(vim.cmd, forward and "cfirst" or "clast")
  end
  vim.cmd("normal! zz")
end
map("n", "]q", function() qf_jump(true) end, { desc = "Next quickfix item" })
map("n", "[q", function() qf_jump(false) end, { desc = "Prev quickfix item" })
map("n", "]Q", "<cmd>silent! clast<cr>zz", { desc = "Last quickfix item" })
map("n", "[Q", "<cmd>silent! cfirst<cr>zz", { desc = "First quickfix item" })

local function toggle_list(loclist)
  return function()
    for _, win in ipairs(vim.fn.getwininfo()) do
      if win.loclist == (loclist and 1 or 0) and win.quickfix == 1 then
        vim.cmd(loclist and "lclose" or "cclose")
        return
      end
    end
    pcall(vim.cmd, loclist and "lopen" or "copen")
  end
end
map("n", "<leader>xq", toggle_list(false), { desc = "Toggle quickfix" })
map("n", "<leader>xl", toggle_list(true), { desc = "Toggle loclist" })

-- Pairs with fzf-lua's <C-q>, which sends a whole grep result to the quickfix list.
map("n", "<leader>xr", function()
  if vim.fn.getqflist({ size = 0 }).size == 0 then
    vim.notify("Quickfix list is empty", vim.log.levels.WARN)
    return
  end
  local pat = vim.fn.input("cdo s/")
  if pat == "" then return end
  -- pcall: a bad pattern or zero substitutions on one entry must not abort the run.
  pcall(vim.cmd, "cdo s/" .. pat .. " | update")
end, { desc = "Replace across quickfix (:cdo)" })

map("n", "<leader>xd", function() vim.diagnostic.setqflist() end, { desc = "Diagnostics → quickfix" })
map("n", "<leader>xt", function() require("core.todo").qflist() end, { desc = "TODOs → quickfix" })
map("n", "<leader>xT", function() require("core.todo").qflist(true) end, { desc = "TODOs in buffer → quickfix" })
map("n", "]t", function() require("core.todo").jump(true) end, { desc = "Next TODO" })
map("n", "[t", function() require("core.todo").jump(false) end, { desc = "Prev TODO" })

-- ── editing ───────────────────────────────────────────────────────────────────

map("n", "<leader>cv", function() require("core.case").pick() end, { desc = "Convert case (picker)" })
map("v", "<", "<gv")
map("v", ">", ">gv")
map("x", "p", [["_dP]], { desc = "Paste without overwrite" })
map("n", "J", "mzJ`z", { desc = "Join lines" })

map("n", "<C-d>", "15jzz", { desc = "Small jump down (centered)" })
map("n", "<C-u>", "15kzz", { desc = "Small jump up (centered)" })
map("n", "n", "nzzzv", { desc = "Next search result (centered)" })
map("n", "N", "Nzzzv", { desc = "Prev search result (centered)" })

-- Baseline maps only: many runtime ftplugins (python, rust, markdown, go) rebind
-- [[/]] buffer-locally to section motions, so core/autocmds.lua re-asserts these
-- per buffer to keep them universal.
local search_cword = require("core.wordsearch").search_cword
map("n", "]]", function() search_cword("n") end, { desc = "Next occurrence of word (text search)" })
map("n", "[[", function() search_cword("N") end, { desc = "Prev occurrence of word (text search)" })

map("n", "gx", function()
  if vim.g.gaf and require("gaf.keymaps").open_phab_under_cursor() then return end
  local cfile = vim.fn.expand("<cfile>")
  if cfile ~= "" then vim.ui.open(cfile) end
end, { desc = "Open URL/file under cursor" })

-- ── harpoon ───────────────────────────────────────────────────────────────────

map("n", "<leader>ha", function() require("core.harpoon").add() end, { desc = "Add file" })
map("n", "<leader>hh", function() require("core.harpoon").menu() end, { desc = "Toggle menu" })
map("n", "<leader>hc", function() require("core.harpoon").clear() end, { desc = "Clear list" })
for i = 1, 5 do
  map("n", "<leader>" .. i, function() require("core.harpoon").select(i) end,
    { desc = "Harpoon file " .. i })
end

-- ── files ─────────────────────────────────────────────────────────────────────

map("n", "<leader>fR", function()
  local old = vim.api.nvim_buf_get_name(0)
  if old == "" then
    vim.notify("Buffer has no file", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Rename to: ", default = old, completion = "file" }, function(new)
    if not new or new == "" or new == old then return end
    vim.fn.mkdir(vim.fn.fnamemodify(new, ":p:h"), "p")
    local renames = { { oldUri = vim.uri_from_fname(old), newUri = vim.uri_from_fname(new) } }
    -- willRenameFiles has to go before the move and didRenameFiles after, or the
    -- servers will not rewrite imports pointing at the old path.
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
      local res = client:request_sync("workspace/willRenameFiles", { files = renames }, 1000)
      if res and res.result then vim.lsp.util.apply_workspace_edit(res.result, client.offset_encoding) end
    end
    local ok, err = vim.uv.fs_rename(old, new)
    if not ok then
      vim.notify("Rename failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.cmd.edit(vim.fn.fnameescape(new))
    vim.cmd("bwipeout! " .. vim.fn.bufnr(old))
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
      client:notify("workspace/didRenameFiles", { files = renames })
    end
    vim.notify(("Renamed → %s"):format(vim.fn.fnamemodify(new, ":~:.")))
  end)
end, { desc = "Rename file" })

-- The one terminal spawn in this config, which deliberately has no terminal
-- plugin and no <leader>/ toggle.
map("n", "<leader>gg", function()
  if vim.fn.executable("lazygit") ~= 1 then
    vim.notify("lazygit not installed", vim.log.levels.WARN)
    return
  end
  vim.cmd("tabnew")
  vim.fn.jobstart({ "lazygit" }, {
    term = true,
    cwd = vim.uv.cwd(),
    on_exit = function() vim.schedule(function() pcall(vim.cmd, "tabclose") end) end,
  })
  vim.cmd.startinsert()
end, { desc = "Lazygit" })

-- ── UI toggles ────────────────────────────────────────────────────────────────

local toggle = require("core.toggle")
toggle.option("spell", { name = "Spelling" }):map("<leader>us")
toggle.option("wrap", { name = "Wrap" }):map("<leader>uw")
toggle.option("conceallevel", { off = 0, on = 2, name = "Conceal" }):map("<leader>uc")
toggle.option("relativenumber", { name = "Relative Number" }):map("<leader>uL")
toggle.option("list", { name = "Listchars" }):map("<leader>ug")
toggle.line_number():map("<leader>ul")
toggle.treesitter():map("<leader>uT")
toggle.inlay_hints():map("<leader>uh")
toggle.diagnostics():map("<leader>ux")
toggle.zen():map("<leader>uz")
toggle.zoom():map("<leader>uZ")
map("n", "<leader>uN", "<cmd>messages<cr>", { desc = "Message history" })
