vim.opt_local.suffixesadd:append(".md")
vim.opt_local.path:append(".")
vim.opt_local.isfname:append("-")

local function open_link()
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col(".")
  local search_from = 1
  while true do
    local s, e, target = line:find("%[[^%]]*%]%(([^%)]+)%)", search_from)
    if not s then break end
    if col >= s and col <= e then
      if target:match("^https?://") or target:match("^[a-z]+://") then
        vim.ui.open(target)
        return true
      end
      local anchor_stripped = target:gsub("#.*$", "")
      if anchor_stripped == "" then return false end
      local dir = vim.fn.expand("%:p:h")
      local resolved = vim.fn.fnamemodify(dir .. "/" .. anchor_stripped, ":p")
      if vim.fn.filereadable(resolved) == 1 or vim.fn.isdirectory(resolved) == 1 then
        vim.cmd.edit(vim.fn.fnameescape(resolved))
        return true
      end
      if vim.fn.filereadable(resolved .. ".md") == 1 then
        vim.cmd.edit(vim.fn.fnameescape(resolved .. ".md"))
        return true
      end
      return false
    end
    search_from = e + 1
  end
  return false
end

vim.keymap.set("n", "gf", function()
  if not open_link() then
    vim.cmd("normal! gf")
  end
end, { buffer = true, desc = "Follow markdown link or file" })
