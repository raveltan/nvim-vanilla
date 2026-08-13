-- ripgrep + jump plumbing shared by every Angular lookup. All resolution here is
-- rg over a search root, never an LSP: one hit jumps straight, several open an
-- fzf-lua picker (the same layer the rest of this config's lists use).
local M = {}

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Angular" })
end

-- Escape rg-regex metacharacters that can appear in identifiers ($ in data$).
function M.rx(s)
  return (s:gsub("([%$%.])", "\\%1"))
end

-- Search root: nearest Angular source ancestor of the current file. Prefer a
-- `webapp/src` (GAF monorepo layout), else any `webapp`, else a plain `src`
-- (standalone Angular repos), else the cwd. Tries the more specific patterns
-- first so a GAF file still narrows to `webapp/src`, not its outer `src`.
function M.search_root(fname)
  return fname:match("(.*/webapp/src)/")
    or fname:match("(.*/webapp)/")
    or fname:match("(.*/src)/")
    or vim.fn.getcwd()
end

-- The `src` dir a file lives under, the import baseUrl in both layouts.
function M.src_root(file)
  return file:match("(.*/webapp/src)/") or file:match("(.*/src)/")
end

function M.buf_root(bufnr)
  return M.search_root(vim.api.nvim_buf_get_name(bufnr or 0))
end

-- ── jump + picker ──────────────────────────────────────────────────────────

function M.jump_to(file, lnum, col)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, col or 0 })
  vim.cmd("normal! zz")
end

function M.jump_item(item)
  M.jump_to(item.file, item.pos[1], item.pos[2])
end

-- Parse `rg --vimgrep` stdout into items.
local function vimgrep_items(stdout)
  local items = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if file then
      items[#items + 1] = {
        text = vim.fn.fnamemodify(file, ":t") .. " " .. (text or ""),
        file = file,
        pos = { tonumber(lnum), tonumber(col) - 1 },
        line = text,
      }
    end
  end
  return items
end

-- Run rg --vimgrep with the given patterns over paths (root dir or files),
-- async, and hand the parsed items to cb on the main loop. ropts.no_type drops
-- the typescript filter (needed when searching explicit .scss files).
function M.rg_run(patterns, paths, cb, ropts)
  ropts = ropts or {}
  local args = { "rg", "--vimgrep", "--no-heading", "--color=never" }
  if not ropts.no_type then
    vim.list_extend(args, { "-t", "ts", "-g", "!*.spec.ts" })
  end
  for _, p in ipairs(patterns) do
    vim.list_extend(args, { "-e", p })
  end
  vim.list_extend(args, paths)
  vim.system(args, { text = true }, function(res)
    vim.schedule(function()
      -- rg exits 1 for "no matches" (fine); anything else is a real failure
      -- (missing binary surfaces as ENOENT before this, bad pattern as 2).
      if res.code > 1 then
        vim.notify("rg failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
        return cb({})
      end
      cb(vimgrep_items(res.stdout))
    end)
  end)
end

-- Entries are written back in rg's own `file:lnum:col:text` shape, which is what
-- fzf-lua's builtin previewer parses -- so the preview window works without any
-- of its grep plumbing, and the action can read the position straight back out.
local function pick(title, items, opts)
  local entries, by_entry = {}, {}
  for _, it in ipairs(items) do
    local shown = opts.filename_only and vim.fn.fnamemodify(it.file, ":t")
      or vim.fn.fnamemodify(it.file, ":.")
    local entry = ("%s:%d:%d:%s"):format(shown, it.pos[1], it.pos[2] + 1, it.line or "")
    entries[#entries + 1] = entry
    by_entry[entry] = it
  end
  require("fzf-lua").fzf_exec(entries, {
    prompt = title .. "> ",
    previewer = "builtin",
    actions = {
      ["default"] = function(sel)
        local it = sel[1] and by_entry[sel[1]]
        if it then M.jump_item(it) end
      end,
    },
  })
end

-- Single hit -> jump straight; many -> picker.
-- opts.jump_first jumps to the first hit regardless of count (exact lookups);
-- opts.dedupe collapses to one item per file; opts.filename_only drops the path
-- from the picker rows.
function M.show(title, items, opts)
  opts = opts or {}
  if opts.skip then
    items = vim.tbl_filter(function(it) return it.file ~= opts.skip end, items)
  end
  if opts.dedupe then
    local seen, uniq = {}, {}
    for _, it in ipairs(items) do
      if not seen[it.file] then
        seen[it.file] = true
        uniq[#uniq + 1] = it
      end
    end
    items = uniq
  end
  if #items == 0 then
    M.notify("No matches for " .. title)
    return
  end
  if opts.jump_first or #items == 1 then
    M.jump_item(items[1])
    return
  end
  pick(title, items, opts)
end

function M.rg_search(title, patterns, root, opts)
  M.rg_run(patterns, { root }, function(items) M.show(title, items, opts) end)
end

return M
