-- The VS Code JSON packs in snippets/, which nothing native loads. This file
-- owns reading them and the vim.snippet jump maps; core/snippet_source.lua puts
-- them in the completion menu.
--
-- A pack's filename is its filetype. snippets/php.json feeds php buffers.

local M = {}

local DIR = vim.fn.stdpath("config") .. "/snippets"
local cache = {} -- filetype -> { {prefix, body, desc}, ... }

local function as_list(v)
  if type(v) == "table" then return v end
  return { v }
end

-- `{ prefix, body, desc }` for a filetype, read once and cached.
function M.for_filetype(ft)
  if cache[ft] then return cache[ft] end
  local out = {}
  local path = DIR .. "/" .. ft .. ".json"
  local fd = io.open(path, "r")
  if fd then
    local content = fd:read("*a")
    fd:close()
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
      for name, snip in pairs(data) do
        if type(snip) == "table" and snip.body then
          local body = table.concat(as_list(snip.body), "\n")
          for _, prefix in ipairs(as_list(snip.prefix or name)) do
            out[#out + 1] = {
              prefix = prefix,
              body = body,
              desc = snip.description and table.concat(as_list(snip.description), " ") or name,
            }
          end
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.prefix < b.prefix end)
  cache[ft] = out
  return out
end

function M.setup()
  vim.keymap.set({ "i", "s" }, "<Tab>", function()
    if vim.snippet.active({ direction = 1 }) then
      return "<Cmd>lua vim.snippet.jump(1)<CR>"
    end
    return "<Tab>"
  end, { expr = true, desc = "Snippet: next placeholder / tab" })

  vim.keymap.set({ "i", "s" }, "<S-Tab>", function()
    if vim.snippet.active({ direction = -1 }) then
      return "<Cmd>lua vim.snippet.jump(-1)<CR>"
    end
    return "<S-Tab>"
  end, { expr = true, desc = "Snippet: prev placeholder" })

  vim.api.nvim_create_user_command("SnippetsReload", function()
    cache = {}
    pcall(function() require("core.snippet_source").reset() end)
    vim.notify("Snippet cache cleared")
  end, { desc = "Re-read snippets/*.json" })

  vim.api.nvim_create_user_command("SnippetsEdit", function()
    local ft = vim.bo.filetype
    if ft == "" then
      vim.notify("Buffer has no filetype", vim.log.levels.WARN)
      return
    end
    cache[ft] = nil
    vim.cmd.edit(vim.fn.fnameescape(DIR .. "/" .. ft .. ".json"))
  end, { desc = "Edit this filetype's snippet pack" })
end

return M
