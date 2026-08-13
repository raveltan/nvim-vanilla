local M = {}

-- Sets the `/` register by hand for a whole-word match, with `\V` to keep symbols
-- literal and `\C` to stay case-sensitive whatever ignorecase/smartcase say. Feeds
-- n/N rather than jumping, so the centering n/N maps in core/keymaps.lua fire and
-- plain n/N keeps cycling afterwards.
function M.search_cword(next_key)
  local w = vim.fn.expand("<cword>")
  if w == "" then return end
  vim.fn.setreg("/", [[\C\V\<]] .. vim.fn.escape(w, [[\]]) .. [[\>]])
  vim.opt.hlsearch = true
  vim.api.nvim_feedkeys(next_key, "m", false)
end

return M
