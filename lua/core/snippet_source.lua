-- blink.cmp source for the JSON packs in snippets/. blink's own snippets source
-- expects a friendly-snippets layout (a package.json naming each pack); these are
-- bare snippets/<filetype>.json files, so they get their own source instead.
local snippets = require("core.snippets")

local kinds = vim.lsp.protocol.CompletionItemKind
local Snippet = vim.lsp.protocol.InsertTextFormat.Snippet

local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

-- Rebuilding the item list on every keystroke would be the expensive half, so the
-- shaped items are cached under the key core.snippets hands back -- a filetype
-- plus its project's overlay packs.
local items_cache = {}

local function items_for(key, snips)
  if items_cache[key] then return items_cache[key] end
  local out = {}
  for i, s in ipairs(snips) do
    out[i] = {
      label = s.prefix,
      filterText = s.prefix,
      sortText = s.prefix,
      kind = kinds.Snippet,
      labelDetails = { description = "snip" },
      insertText = s.body,
      insertTextFormat = Snippet,
      documentation = { kind = "markdown", value = s.desc .. "\n\n```\n" .. s.body .. "\n```" },
    }
  end
  items_cache[key] = out
  return out
end

-- :SnippetsReload drops the raw packs; the shaped items have to go with them.
function M.reset()
  items_cache = {}
end

function M:get_completions(_, callback)
  callback({
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = items_for(snippets.for_buffer()),
  })
end

return M
