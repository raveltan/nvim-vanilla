local M = {}

M.fl_gaf = vim.fn.expand("~/freelancer-dev/fl-gaf")

function M.find_root(rel, from)
  local dir = from or vim.fn.getcwd()
  if dir == "" then dir = vim.fn.getcwd() end
  if vim.fn.isdirectory(dir) == 0 then dir = vim.fs.dirname(dir) end
  while dir and dir ~= "" and dir ~= "/" do
    if vim.uv.fs_stat(dir .. "/" .. rel) then return dir end
    dir = vim.fs.dirname(dir)
  end
  return nil
end

-- Deliberately not `expand("%:p:.")`, which is relative to cwd. Every consumer
-- compares against paths .arclint expresses from the repo root, so nvim started
-- anywhere else would route src2 files to the wrong ruleset.
function M.gaf_relpath(bufnr)
  local abs = vim.api.nvim_buf_get_name(bufnr or 0)
  if abs == "" then return nil end
  local root = M.fl_gaf .. "/"
  if abs:sub(1, #root) ~= root then return nil end
  return abs:sub(#root + 1)
end

-- Webapp root = directory whose package.json defines the "ui:main" script.
-- Handles both shapes: `start` is inside the webapp itself (UI-test spec
-- buffers) or the webapp/ is a child of an ancestor (monorepo cwd).
function M.webapp_root(start)
  local function is_webapp(dir)
    local pkg = dir .. "/package.json"
    if vim.fn.filereadable(pkg) ~= 1 then return false end
    local content = table.concat(vim.fn.readfile(pkg), "\n")
    return content:find('"ui:main"', 1, true) ~= nil
  end
  local dir = start or vim.fn.getcwd()
  if vim.fn.isdirectory(dir) == 0 then dir = vim.fs.dirname(dir) end
  while dir and dir ~= "" and dir ~= "/" do
    if is_webapp(dir) then return dir end
    local child = dir .. "/webapp"
    if vim.fn.isdirectory(child) == 1 and is_webapp(child) then return child end
    dir = vim.fs.dirname(dir)
  end
  return nil
end

return M
