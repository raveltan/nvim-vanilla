-- Native statusline. 'laststatus' is 3, so one bar renders per screen and it is
-- rebuilt on every redraw, which is what the caching below is for.

local harpoon_list = require("core.harpoon").list

local M = {}

-- moonfly palette, so the accents match the theme without pulling its module.
local C = {
  fg      = "#c6c6c6",
  grey    = "#8b8b8b",
  dark    = "#5c6370",
  blue    = "#80a0ff",
  green   = "#8cc85f",
  yellow  = "#e3c78a",
  red     = "#ff5454",
  purple  = "#cf87e8",
  cyan    = "#79dac8",
  bg      = "#323437",
}

local function set_highlights()
  local function hl(name, spec) vim.api.nvim_set_hl(0, name, spec) end
  hl("StlMode",      { fg = C.bg, bg = C.blue, bold = true })
  hl("StlModeI",     { fg = C.bg, bg = C.green, bold = true })
  hl("StlModeV",     { fg = C.bg, bg = C.purple, bold = true })
  hl("StlModeR",     { fg = C.bg, bg = C.red, bold = true })
  hl("StlModeC",     { fg = C.bg, bg = C.yellow, bold = true })
  hl("StlBranch",    { fg = C.purple })
  hl("StlDir",       { fg = C.grey })
  hl("StlFile",      { fg = C.fg, bold = true })
  hl("StlModified",  { fg = C.yellow })
  hl("StlError",     { fg = C.red })
  hl("StlWarn",      { fg = C.yellow })
  hl("StlInfo",      { fg = C.blue })
  hl("StlHint",      { fg = C.cyan })
  hl("StlLsp",       { fg = C.dark })
  hl("StlHarpoon",   { fg = C.cyan })
  hl("StlHarpoonOn", { fg = C.bg, bg = C.cyan, bold = true })
  hl("StlMacro",     { fg = C.red, bold = true })
  hl("StlPos",       { fg = C.grey })
end

local MODES = {
  n = { "NORMAL", "StlMode" },   no = { "O-PEND", "StlMode" },
  v = { "VISUAL", "StlModeV" },  V = { "V-LINE", "StlModeV" },
  ["\22"] = { "V-BLCK", "StlModeV" },
  s = { "SELECT", "StlModeV" },  S = { "S-LINE", "StlModeV" },
  i = { "INSERT", "StlModeI" },  ic = { "INSERT", "StlModeI" },
  R = { "REPLCE", "StlModeR" },  Rv = { "V-RPLC", "StlModeR" },
  c = { "CMMAND", "StlModeC" },  t = { "TERMNL", "StlModeC" },
}

local function group(text, h)
  return ("%%#%s#%s%%*"):format(h, text)
end

local function mode()
  local m = MODES[vim.api.nvim_get_mode().mode] or { "??????", "StlMode" }
  return group(" " .. m[1] .. " ", m[2])
end

local function macro()
  local r = vim.fn.reg_recording()
  if r == "" then return "" end
  return group(("  REC @%s "):format(r), "StlMacro")
end

-- gitsigns publishes b:gitsigns_head, so no git process is spawned here.
local function branch()
  local head = vim.b.gitsigns_head or vim.g.gitsigns_head
  if not head or head == "" then return "" end
  return group((" %s "):format(head), "StlBranch")
end

local function gitdiff()
  local d = vim.b.gitsigns_status_dict
  if not d then return "" end
  local out = {}
  if (d.added or 0) > 0 then out[#out + 1] = group("+" .. d.added, "StlHint") end
  if (d.changed or 0) > 0 then out[#out + 1] = group("~" .. d.changed, "StlWarn") end
  if (d.removed or 0) > 0 then out[#out + 1] = group("-" .. d.removed, "StlError") end
  if #out == 0 then return "" end
  return table.concat(out, " ") .. " "
end

local SEV = {
  { vim.diagnostic.severity.ERROR, " ", "StlError" },
  { vim.diagnostic.severity.WARN,  " ", "StlWarn" },
  { vim.diagnostic.severity.INFO,  " ", "StlInfo" },
  { vim.diagnostic.severity.HINT,  " ", "StlHint" },
}

-- The four filtered get() calls this replaced each allocated a table of matching
-- diagnostics, 21.7µs per redraw on a buffer with 40 of them. count() returns
-- every severity in one pass, 1.6µs.
local function diagnostics()
  if not vim.diagnostic.is_enabled({ bufnr = 0 }) then return "" end
  local counts = vim.diagnostic.count(0)
  local out = {}
  for _, s in ipairs(SEV) do
    local n = counts[s[1]]
    if n and n > 0 then out[#out + 1] = group(s[2] .. n, s[3]) end
  end
  if #out == 0 then return "" end
  return table.concat(out, " ") .. " "
end

-- The winbar already carries the bare filename per window, so the one global
-- statusline shows which tree the cursor is in instead.
--
-- Cached per buffer because fnamemodify's `:.` calls getcwd(), 7µs on macOS, and
-- this ran on every redraw. M.setup invalidates it on DirChanged/BufFilePost.
local function dirname()
  if vim.bo.buftype ~= "" then return "" end
  local cached = vim.b.stl_dir
  if cached == nil then
    local d = vim.fn.fnamemodify(vim.fn.expand("%:p:h"), ":~:.")
    cached = (d == "" or d == ".") and "" or (d .. " ")
    vim.b.stl_dir = cached
  end
  if cached == "" then return "" end
  return group(cached, "StlDir")
end

local function harpoon()
  local list = harpoon_list()
  if #list == 0 then return "" end
  local cur = vim.api.nvim_buf_get_name(0)
  local out = {}
  for i, path in ipairs(list) do
    out[#out + 1] = group(" " .. i .. " ", path == cur and "StlHarpoonOn" or "StlHarpoon")
  end
  return table.concat(out) .. " "
end

-- vim.lsp.status() is already throttled by the progress ring buffer, so nothing
-- here needs debouncing.
local function lsp_progress()
  local s = vim.lsp.status()
  if s == "" then return "" end
  if #s > 40 then s = s:sub(1, 39) .. "…" end
  return group(s .. " ", "StlLsp")
end

local function lsp_clients()
  local cs = vim.lsp.get_clients({ bufnr = 0 })
  if #cs == 0 then return "" end
  local names = {}
  for _, c in ipairs(cs) do names[#names + 1] = c.name end
  return group((" %s "):format(table.concat(names, ",")), "StlLsp")
end

function M.render()
  return table.concat({
    mode(),
    macro(),
    " ",
    branch(),
    gitdiff(),
    "%<", -- truncate from here when the bar overflows
    dirname(),
    "%=",
    harpoon(),
    "%S ", -- pending keys, routed here by showcmdloc=statusline
    "%=",
    diagnostics(),
    lsp_progress(),
    lsp_clients(),
    group(" %{&filetype} ", "StlDir"),
    group(" %l:%c ", "StlPos"),
    group(" %P ", "StlPos"),
  })
end

local SKIP_WINBAR = {
  ["oil"] = true, ["qf"] = true, ["help"] = true, ["fzf"] = true,
  ["checkhealth"] = true, ["gitcommit"] = true, ["git"] = true,
  ["neotest-summary"] = true, ["neotest-output-panel"] = true,
}

function M.winbar()
  local name = vim.fn.expand("%:t")
  if name == "" then return "" end
  return group(" " .. name, "StlFile") .. (vim.bo.modified and group(" ●", "StlModified") or "")
end

local function apply_winbar(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  if vim.api.nvim_win_get_config(win).relative ~= "" then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local skip = vim.bo[buf].buftype ~= "" or SKIP_WINBAR[vim.bo[buf].filetype]
  vim.wo[win].winbar = skip and "" or "%!v:lua.require'core.statusline'.winbar()"
end

function M.setup()
  set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("statusline_hl", { clear = true }),
    callback = set_highlights,
  })
  vim.o.statusline = "%!v:lua.require'core.statusline'.render()"

  local g = vim.api.nvim_create_augroup("statusline_winbar", { clear = true })
  -- The bar itself is a %! expression, so only the winbar needs re-applying, and
  -- only when the window, its buffer or that buffer's filetype changes.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "FileType" }, {
    group = g,
    callback = function() apply_winbar(vim.api.nvim_get_current_win()) end,
  })
  -- Nothing else redraws the statusline while the cursor sits still. The User
  -- event gets its own autocmd because a shared `"*"` pattern made every
  -- plugin's User event force a redraw.
  local function redraw() vim.cmd.redrawstatus() end
  vim.api.nvim_create_autocmd({ "LspProgress", "DiagnosticChanged" }, { group = g, callback = redraw })
  vim.api.nvim_create_autocmd("User", { group = g, pattern = "GitSignsUpdate", callback = redraw })

  vim.api.nvim_create_autocmd({ "DirChanged", "BufFilePost" }, {
    group = g,
    callback = function()
      -- `:.` is cwd-relative, so a cd invalidates every buffer's cached dirname.
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        vim.b[buf].stl_dir = nil
      end
      redraw()
    end,
  })
end

return M
