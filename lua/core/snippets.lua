-- The VS Code JSON packs in snippets/, which nothing native loads. This file
-- owns reading them and the vim.snippet jump maps; core/snippet_source.lua puts
-- them in the completion menu.
--
-- A pack's filename is its filetype. snippets/php.json feeds php buffers.
--
-- Packs in a subdirectory are overlays, stacked on the base pack only in a
-- matching project: snippets/laravel/php.json in a Laravel checkout and nowhere
-- else. LuaSnip needed the GAF profile switch for this because its registry is
-- global and per session; packs here are read per buffer, so the project itself
-- can be the gate.

local M = {}

local DIR = vim.fn.stdpath("config") .. "/snippets"

local packs = {} -- path -> { {prefix, body, desc}, ... }
local composed = {} -- cache key -> base pack plus its overlays
local stacks = {} -- project root (or false) -> overlay names

local function as_list(v)
  if type(v) == "table" then return v end
  return { v }
end

local function read_pack(path)
  if packs[path] then return packs[path] end
  local out = {}
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
  packs[path] = out
  return out
end

-- laravel/ in any Laravel checkout, pest/ on top of it when the project runs
-- Pest. fl-gaf has no `artisan`, so the monolith gets neither. Cached per root
-- because this runs on every completion request and the Pest check is a stat.
local function overlays_for(root)
  local key = root or false
  if not stacks[key] then
    if not root then
      stacks[key] = {}
    elseif vim.uv.fs_stat(root .. "/tests/Pest.php") then
      stacks[key] = { "laravel", "pest" }
    else
      stacks[key] = { "laravel" }
    end
  end
  return stacks[key]
end

--- A buffer's snippets: its filetype's pack plus whatever overlays the buffer's
--- project activates. Order is left to blink, which ranks by score then by the
--- item's sortText. The returned key identifies the combination, so callers that
--- shape the list further (core/snippet_source.lua) can cache under it.
---@return string key, table snips
function M.for_buffer(bufnr)
  local ft = vim.bo[bufnr or 0].filetype
  if ft == "" then return "", {} end

  local base = DIR .. "/" .. ft .. ".json"
  local names = overlays_for(require("artisan").root(bufnr))
  if #names == 0 then return ft, read_pack(base) end

  local key = ft .. ":" .. table.concat(names, ",")
  if not composed[key] then
    local out = vim.list_extend({}, read_pack(base))
    for _, name in ipairs(names) do
      vim.list_extend(out, read_pack(DIR .. "/" .. name .. "/" .. ft .. ".json"))
    end
    composed[key] = out
  end
  return key, composed[key]
end

local function reset()
  packs, composed, stacks = {}, {}, {}
  require("core.snippet_source").reset()
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
    reset()
    vim.notify("Snippet cache cleared")
  end, { desc = "Re-read snippets/*.json" })

  vim.api.nvim_create_user_command("SnippetsEdit", function(opts)
    local ft = vim.bo.filetype
    if ft == "" then
      vim.notify("Buffer has no filetype", vim.log.levels.WARN)
      return
    end
    -- The pack is about to change on disk, and an overlay edit changes the
    -- composed list of every project that stacks it.
    reset()
    local sub = opts.args ~= "" and (opts.args .. "/") or ""
    vim.cmd.edit(vim.fn.fnameescape(DIR .. "/" .. sub .. ft .. ".json"))
  end, {
    nargs = "?",
    complete = function() return { "laravel", "pest" } end,
    desc = "Edit this filetype's snippet pack ([overlay] = laravel, pest)",
  })
end

return M
