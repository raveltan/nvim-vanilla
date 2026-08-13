-- The token scan takes the whole [%w_-] run rather than <cword>, which stops at
-- `-` and so only ever saw `hello` in a kebab token like `hello-world`.

local M = {}

local function words(s)
  s = s:gsub("([%l%d])(%u)", "%1 %2")      -- fooBar -> foo Bar
  s = s:gsub("(%u+)(%u%l)", "%1 %2")       -- HTTPServer -> HTTP Server
  s = s:gsub("[_%-%s]+", " ")
  local out = {}
  for w in s:gmatch("%S+") do out[#out + 1] = w:lower() end
  return out
end

local function capitalize(w)
  return w:sub(1, 1):upper() .. w:sub(2)
end

M.conversions = {
  { label = "snake_case", fn = function(s) return table.concat(words(s), "_") end },
  { label = "camelCase", fn = function(s)
      local w = words(s)
      for i = 2, #w do w[i] = capitalize(w[i]) end
      return table.concat(w)
    end },
  { label = "PascalCase", fn = function(s)
      local w = words(s)
      for i = 1, #w do w[i] = capitalize(w[i]) end
      return table.concat(w)
    end },
  { label = "UPPER_CASE", fn = function(s) return table.concat(words(s), "_"):upper() end },
  { label = "kebab-case", fn = function(s) return table.concat(words(s), "-") end },
}

-- The returned start is 0-based and the end is 1-based inclusive, which is what
-- nvim_buf_set_text wants.
local function token_at_cursor(line, col)
  local function is_tok(c) return c ~= "" and c:match("[%w_%-]") ~= nil end
  local s = col
  while s > 0 and is_tok(line:sub(s, s)) do s = s - 1 end
  if not is_tok(line:sub(s + 1, s + 1)) then s = s + 1 end
  local e = col + 1
  while e < #line and is_tok(line:sub(e + 1, e + 1)) do e = e + 1 end
  local token = line:sub(s + 1, e)
  if not is_tok(token) then return nil end
  return token, s, e
end

function M.pick()
  local win = vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_cursor(win) -- 1-based row, 0-based col
  local row, col = pos[1] - 1, pos[2]
  local line = vim.api.nvim_get_current_line()

  local token, s, e = token_at_cursor(line, col)
  if not token then
    vim.notify("No identifier under cursor", vim.log.levels.WARN)
    return
  end

  vim.ui.select(M.conversions, {
    prompt = "Convert case:",
    format_item = function(item) return ("%-12s %s"):format(item.label, item.fn(token)) end,
  }, function(choice)
    if not choice or not vim.api.nvim_win_is_valid(win) then return end
    vim.api.nvim_buf_set_text(0, row, s, row, e, { choice.fn(token) })
  end)
end

return M
