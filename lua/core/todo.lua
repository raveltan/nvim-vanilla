-- Highlighting is one matchadd() per window, the lists come from rg. No extmark
-- engine and no per-buffer parse.

local M = {}

local HL = {
  TODO = "TodoFgTodo",
  FIX = "TodoFgFix", FIXME = "TodoFgFix", BUG = "TodoFgFix",
  HACK = "TodoFgHack", WARN = "TodoFgHack", WARNING = "TodoFgHack",
  PERF = "TodoFgPerf",
  NOTE = "TodoFgNote",
  TEST = "TodoFgTest",
}

local COLORS = {
  TodoFgTodo = "#80a0ff", TodoFgFix = "#ff5454", TodoFgHack = "#e3c78a",
  TodoFgPerf = "#cf87e8", TodoFgNote = "#8cc85f", TodoFgTest = "#79dac8",
}

local keywords = vim.tbl_keys(HL)
table.sort(keywords)

-- \b on both sides keeps FIX from swallowing FIXME regardless of alternation order.
local PATTERN = "\\b(" .. table.concat(keywords, "|") .. ")\\b:?"

function M.qflist(buffer_only)
  if vim.fn.executable("rg") ~= 1 then
    vim.notify("rg not found", vim.log.levels.ERROR)
    return
  end
  local file = buffer_only and vim.fn.expand("%:p") or nil
  if buffer_only and file == "" then return end

  -- rg respects .gitignore, so generated trees stay out of the list.
  local cmd = { "rg", "--vimgrep", "--no-heading", "--smart-case", "-e", PATTERN }
  if file then cmd[#cmd + 1] = file end

  vim.system(cmd, { text = true, cwd = vim.uv.cwd() }, vim.schedule_wrap(function(res)
    local lines = vim.split(res.stdout or "", "\n", { trimempty = true })
    if #lines == 0 then
      vim.notify("No TODO comments found", vim.log.levels.WARN)
      return
    end
    vim.fn.setqflist({}, " ", {
      title = buffer_only and "TODOs (buffer)" or "TODOs",
      lines = lines,
      efm = "%f:%l:%c:%m",
    })
    vim.cmd("copen")
  end))
end

-- Plain search so it wraps and populates the / register like any other motion.
function M.jump(forward)
  vim.fn.search([[\v<(]] .. table.concat(keywords, "|") .. [[)>:?]], forward and "w" or "bw")
end

local function set_highlights()
  for name, fg in pairs(COLORS) do
    vim.api.nvim_set_hl(0, name, { fg = fg, bold = true })
  end
end

-- One match per highlight group, not per keyword. Each matchadd leaves a
-- window-local regex the redraw engine runs over every visible line for the life
-- of the window, and ten of them cost 0.22ms per split to install.
local GROUPS = {}
for kw, hl in pairs(HL) do
  GROUPS[hl] = GROUPS[hl] and (GROUPS[hl] .. "|" .. kw) or kw
end

local function decorate(win)
  if vim.w[win].todo_matched then return end
  if vim.api.nvim_win_get_config(win).relative ~= "" then return end
  if vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= "" then return end
  vim.w[win].todo_matched = true
  vim.api.nvim_win_call(win, function()
    for hl, alt in pairs(GROUPS) do
      pcall(vim.fn.matchadd, hl, [[\v<(]] .. alt .. [[)>:?]], -1)
    end
  end)
end

function M.setup()
  set_highlights()
  local g = vim.api.nvim_create_augroup("todo_comments", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = g, callback = set_highlights })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinNew" }, {
    group = g,
    callback = function() decorate(vim.api.nvim_get_current_win()) end,
  })
  vim.api.nvim_create_user_command("Todo", function(a) M.qflist(a.bang) end,
    { bang = true, desc = "TODO comments -> quickfix (! = this buffer only)" })
end

return M
