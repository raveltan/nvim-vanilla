-- Marks render in the statusline rather than a tabline, since 'showtabline' is 0.

local M = {}

local FILE = vim.fn.stdpath("state") .. "/harpoon.json"
local MAX = 5

local db, dirty = nil, false

-- Memoised because the statusline component calls this on every redraw and
-- vim.uv.cwd() is a 7µs syscall on macOS. DirChanged is what invalidates it, and
-- it covers :cd/:lcd/:tcd and 'autochdir'.
local cwd
local function key()
  if not cwd then cwd = vim.uv.cwd() or "/" end
  return cwd
end

vim.api.nvim_create_autocmd("DirChanged", {
  group = vim.api.nvim_create_augroup("harpoon_cwd", { clear = true }),
  callback = function() cwd = nil end,
})

local function read()
  if db then return db end
  db = {}
  local fd = io.open(FILE, "r")
  if fd then
    local content = fd:read("*a")
    fd:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if ok and type(decoded) == "table" then db = decoded end
  end
  return db
end

local function flush()
  if not dirty then return end
  dirty = false
  local fd = io.open(FILE, "w")
  if not fd then return end
  fd:write(vim.json.encode(db or {}))
  fd:close()
end

function M.list()
  local d = read()
  return d[key()] or {}
end

local function save(list)
  local d = read()
  d[key()] = list
  dirty = true
  flush()
end

function M.add()
  local path = vim.fn.expand("%:p")
  if path == "" or vim.bo.buftype ~= "" then
    vim.notify("Not a file buffer", vim.log.levels.WARN)
    return
  end
  local list = vim.deepcopy(M.list())
  for i, p in ipairs(list) do
    if p == path then
      vim.notify(("Already harpooned at %d"):format(i))
      return
    end
  end
  if #list >= MAX then
    vim.notify(("Harpoon list is full (%d)"):format(MAX), vim.log.levels.WARN)
    return
  end
  list[#list + 1] = path
  save(list)
  vim.notify(("Harpooned %d: %s"):format(#list, vim.fn.fnamemodify(path, ":~:.")))
end

function M.select(n)
  local list = M.list()
  local path = list[n]
  if not path then
    vim.notify(("No harpoon file %d"):format(n), vim.log.levels.WARN)
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

-- The buffer is the list, so reordering is dd/p or :m and removal is dd, exactly
-- as upstream harpoon's menu behaves.
function M.menu()
  local list = M.list()
  local display = vim.tbl_map(function(p) return vim.fn.fnamemodify(p, ":~:.") end, list)
  if #display == 0 then display = { "" } end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "harpoon"

  local width = math.min(math.max(60, vim.o.columns - 20), math.floor(vim.o.columns * 0.8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = math.max(#display, 1),
    row = math.floor((vim.o.lines - #display) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " harpoon ",
  })
  vim.wo[win].number = true

  local function persist()
    local out = {}
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      l = vim.trim(l)
      if l ~= "" then out[#out + 1] = vim.fn.fnamemodify(l, ":p") end
    end
    save(out)
  end

  local function close()
    persist()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  vim.keymap.set("n", "<CR>", function()
    local l = vim.trim(vim.api.nvim_get_current_line())
    close()
    if l ~= "" then vim.cmd.edit(vim.fn.fnameescape(vim.fn.fnamemodify(l, ":p"))) end
  end, { buffer = buf, nowait = true })
  for _, k in ipairs({ "q", "<esc>" }) do
    vim.keymap.set("n", k, close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = persist })
end

function M.clear()
  save({})
  vim.notify("Harpoon list cleared")
end

return M
