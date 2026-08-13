-- Each entry knows its own state, so which-key can render an Enable/Disable
-- description and a flip can notify, none of which a raw
-- `vim.wo.wrap = not vim.wo.wrap` gets.

local M = {}

local Toggle = {}
Toggle.__index = Toggle

function Toggle:map(lhs)
  vim.keymap.set("n", lhs, function() self:flip() end, {
    desc = "Toggle " .. self.name,
    silent = true,
  })
  -- which-key colours the entry and swaps the icon from these. Deferred because
  -- :map() runs at startup and which-key only loads on VeryLazy.
  vim.api.nvim_create_autocmd("User", {
    pattern = "VeryLazy",
    once = true,
    callback = function()
      pcall(function()
        require("which-key").add({
          {
            lhs,
            desc = function() return (self:get() and "Disable " or "Enable ") .. self.name end,
            icon = function()
              return { icon = self:get() and " " or " ", color = self:get() and "green" or "yellow" }
            end,
          },
        })
      end)
    end,
  })
  return self
end

function Toggle:get() return self._get() end
function Toggle:set(v) self._set(v) end

function Toggle:flip()
  local to = not self:get()
  self:set(to)
  vim.notify(("%s %s"):format(self.name, to and "enabled" or "disabled"),
    vim.log.levels.INFO, { title = "Toggle" })
end

local function new(name, get, set)
  return setmetatable({ name = name, _get = get, _set = set }, Toggle)
end

function M.option(o, opts)
  opts = opts or {}
  local on, off = opts.on, opts.off
  if on == nil then on, off = true, false end
  local scope = vim.api.nvim_get_option_info2(o, {}).scope
  local function read()
    if scope == "win" then return vim.wo[o] end
    if scope == "buf" then return vim.bo[o] end
    return vim.o[o]
  end
  local function write(v)
    if scope == "win" then vim.wo[o] = v
    elseif scope == "buf" then vim.bo[o] = v
    else vim.o[o] = v end
  end
  return new(opts.name or o, function() return read() == on end,
    function(v) write(v and on or off) end)
end

function M.treesitter()
  return new("Treesitter Highlight",
    function() return vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil end,
    function(v)
      if v then pcall(vim.treesitter.start) else pcall(vim.treesitter.stop) end
    end)
end

function M.inlay_hints()
  return new("Inlay Hints",
    function() return vim.lsp.inlay_hint.is_enabled({ bufnr = 0 }) end,
    function(v) vim.lsp.inlay_hint.enable(v, { bufnr = 0 }) end)
end

function M.diagnostics()
  return new("Diagnostics",
    function() return vim.diagnostic.is_enabled() end,
    function(v) vim.diagnostic.enable(v) end)
end

-- comfy-line-numbers owns 'statuscolumn' globally and never consults 'number',
-- so clearing the options alone leaves numbers rendering through its column. Its
-- own disable_line_numbers() unbinds the label maps and nothing else, and its
-- augroup re-asserts the column on seven events, so the augroup has to go too.
-- setup() is idempotent and puts both back.
local function comfy(on)
  local ok, c = pcall(require, "comfy-line-numbers")
  if not ok then return end
  if on then
    c.setup({})
  else
    c.disable_line_numbers()
    pcall(vim.api.nvim_del_augroup_by_name, "ComfyLineNumbers")
    vim.o.statuscolumn = ""
  end
end

function M.line_number()
  return new("Line Numbers",
    function() return vim.wo.number or vim.wo.relativenumber end,
    function(v)
      comfy(v)
      vim.wo.number = v
      vim.wo.relativenumber = v
    end)
end

-- A tab rather than <C-w>o, which would destroy the split layout.
local function maximise(on, flag)
  if on then
    local buf, pos = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
    vim.cmd("tab split")
    vim.t[flag] = true
    vim.api.nvim_win_set_buf(0, buf)
    pcall(vim.api.nvim_win_set_cursor, 0, pos)
  elseif vim.fn.tabpagenr("$") > 1 then
    vim.cmd("tabclose")
  end
end

function M.zoom()
  return new("Zoom",
    function() return vim.t.zoomed == true end,
    function(v) maximise(v, "zoomed") end)
end

-- Its own tab flag rather than zoom's. Sharing `vim.t.zoomed` let <leader>uZ
-- inside zen close the tab with zen_saved still set, stranding laststatus=0.
local zen_saved
function M.zen()
  return new("Zen Mode",
    function() return zen_saved ~= nil end,
    function(v)
      if v then
        zen_saved = {
          win = {
            number = vim.wo.number, relativenumber = vim.wo.relativenumber,
            signcolumn = vim.wo.signcolumn, cursorline = vim.wo.cursorline,
            list = vim.wo.list, colorcolumn = vim.wo.colorcolumn,
          },
          laststatus = vim.o.laststatus,
          comfy = vim.o.statuscolumn ~= "",
        }
        maximise(true, "zen")
        -- comfy-line-numbers re-asserts 'statuscolumn' on InsertEnter, so
        -- blanking the option alone does not keep the gutter clear.
        comfy(false)
        vim.wo.number, vim.wo.relativenumber = false, false
        vim.wo.signcolumn = "no"
        vim.wo.cursorline, vim.wo.list = false, false
        vim.wo.colorcolumn = ""
        vim.o.laststatus = 0
      else
        local s = zen_saved
        zen_saved = nil
        if not s then return end
        vim.o.laststatus = s.laststatus
        maximise(false, "zen")
        -- comfy first, because its setup() forces relativenumber and the saved
        -- window options have to land after that.
        if s.comfy then comfy(true) end
        for k, val in pairs(s.win) do
          pcall(function() vim.wo[k] = val end)
        end
      end
    end)
end

return M
