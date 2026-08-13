-- Deferred-loading layer over vim.pack, and the reason this is not one
-- vim.pack.add() call at the top: add() during init.lua sourcing, even with
-- `load = false`, puts the plugin directory on 'runtimepath' before Neovim's own
-- plugin-loading startup phase, which then sources every plugin/ script it finds
-- there (16 measured). Deferral therefore means not calling add() until a trigger
-- fires.
--
-- Spec fields:
--   src       repo URL (required)
--   name      package name (default: last path segment)
--   version   branch / tag / commit
--   config    function run once the plugin loads
--   deps      names of other specs to load first
--   now       load during startup (colorscheme)
--   data      put on rtp but never source plugin/, for packages that are only
--             data files read by Neovim itself (nvim-lspconfig's lsp/*.lua)
--   event     "BufReadPre" | { "BufReadPre", "BufNewFile" } | "User VeryLazy"
--   ft        filetype(s)
--   cmd       ex command(s) that pull the plugin in
--   keys      { { lhs, rhs, desc = , mode = }, ... }
--   (no trigger at all = dependency, loaded via deps or an explicit pack.load)

local M = {}

local specs, order, loaded = {}, {}, {}

local function derive_name(spec)
  return spec.name or spec.src:gsub("%.git$", ""):match("([^/]+)$")
end

local function tolist(v)
  if v == nil then return {} end
  return type(v) == "table" and v or { v }
end

function M.load(name)
  if loaded[name] then return true end
  local spec = specs[name]
  if not spec then return false end
  loaded[name] = true

  for _, dep in ipairs(tolist(spec.deps)) do M.load(dep) end

  -- Outside init.lua the startup plugin pass is over, so load=false (`:packadd!`)
  -- lands a data-only package on 'runtimepath' without sourcing its plugin/ scripts.
  local ok, err = pcall(vim.pack.add,
    { { src = spec.src, name = name, version = spec.version } },
    { load = not spec.data, confirm = false })
  if not ok then
    vim.notify(("[pack] %s install failed:\n%s"):format(name, err), vim.log.levels.ERROR)
    return false
  end

  if spec.config then
    local cok, cerr = pcall(spec.config)
    if not cok then
      vim.notify(("[pack] %s config failed:\n%s"):format(name, cerr), vim.log.levels.ERROR)
    end
  end
  return true
end

-- Re-fired so a just-loaded plugin's ftplugin/ sees the buffer that triggered it.
-- The guard stops another spec's ft trigger recursing back in here.
local refiring = false
local function refire_filetype(buf)
  if refiring or not vim.api.nvim_buf_is_valid(buf) then return end
  refiring = true
  pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = buf, modeline = false })
  refiring = false
end

local function wire(name, spec)
  local group = vim.api.nvim_create_augroup("pack." .. name, { clear = true })

  for _, ev in ipairs(tolist(spec.event)) do
    local event, pattern = ev, nil
    local e, p = ev:match("^(%S+)%s+(%S+)$")
    if e then event, pattern = e, p end
    vim.api.nvim_create_autocmd(event, {
      group = group,
      pattern = pattern,
      once = true,
      callback = function() M.load(name) end,
    })
  end

  local fts = tolist(spec.ft)
  if #fts > 0 then
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = fts,
      once = true,
      callback = function(ev)
        M.load(name)
        refire_filetype(ev.buf)
      end,
    })
  end

  for _, cmd in ipairs(tolist(spec.cmd)) do
    vim.api.nvim_create_user_command(cmd, function(a)
      pcall(vim.api.nvim_del_user_command, cmd)
      M.load(name)
      local line = cmd .. (a.bang and "!" or "")
      if a.range and a.range > 0 then line = a.line1 .. "," .. a.line2 .. line end
      vim.cmd(vim.trim(line .. " " .. a.args))
    end, { bang = true, nargs = "*", range = true, desc = "load " .. name })
  end

  for _, k in ipairs(spec.keys or {}) do
    local lhs, rhs = k[1], k[2]
    vim.keymap.set(k.mode or "n", lhs, function()
      M.load(name)
      if type(rhs) == "function" then
        rhs()
      else
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(rhs, true, false, true), "m", false)
      end
    end, { desc = k.desc, silent = true })
  end
end

function M.setup(list)
  for _, spec in ipairs(list) do
    if spec.enabled ~= false then
      local name = derive_name(spec)
      spec.name = name
      specs[name] = spec
      order[#order + 1] = name
    end
  end

  for _, name in ipairs(order) do
    local spec = specs[name]
    if spec.now then
      M.load(name)
    elseif spec.event or spec.ft or spec.cmd or spec.keys then
      wire(name, spec)
    end
    -- else: dependency, reached via `deps` or an explicit pack.load()
  end

  -- Scheduled off UIEnter so VeryLazy fires after the first screen is drawn.
  vim.api.nvim_create_autocmd("UIEnter", {
    group = vim.api.nvim_create_augroup("pack.verylazy", { clear = true }),
    once = true,
    callback = function()
      vim.schedule(function()
        vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
      end)
    end,
  })

  vim.api.nvim_create_user_command("PackLoad", function(a)
    if a.args == "" then
      for _, n in ipairs(order) do M.load(n) end
    else
      M.load(a.args)
    end
  end, {
    nargs = "?",
    complete = function() return vim.deepcopy(order) end,
    desc = "Load a deferred plugin now (no arg = all)",
  })

  -- Only plugins missing from disk are passed to vim.pack.add, so an
  -- already-installed setup is a no-op and nothing loads early.
  vim.api.nvim_create_user_command("PackInstall", function()
    local missing = {}
    local root = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
    for _, n in ipairs(order) do
      if not vim.uv.fs_stat(root .. n) then
        missing[#missing + 1] = { src = specs[n].src, name = n, version = specs[n].version }
      end
    end
    if #missing == 0 then
      vim.notify("All plugins already installed")
      return
    end
    vim.pack.add(missing, { load = false, confirm = false })
    vim.notify(("Installed %d plugin(s). Restart to use them."):format(#missing))
  end, { desc = "Clone any not-yet-installed plugins" })

  vim.api.nvim_create_user_command("PackStatus", function()
    local root = vim.fn.stdpath("data") .. "/site/pack/core/opt/"
    local lines = {}
    for _, n in ipairs(order) do
      lines[#lines + 1] = ("%-32s %-9s %s"):format(n,
        loaded[n] and "loaded" or "deferred",
        vim.uv.fs_stat(root .. n) and "" or "NOT INSTALLED")
    end
    vim.notify(table.concat(lines, "\n"))
  end, { desc = "Show pack install/load state" })

  vim.api.nvim_create_user_command("PackUpdate", function()
    -- vim.pack.update() only knows about plugins added this session.
    for _, n in ipairs(order) do M.load(n) end
    vim.pack.update()
  end, { desc = "Load everything, then update all plugins" })

  vim.api.nvim_create_user_command("PackClean", function()
    local keep = {}
    for _, n in ipairs(order) do keep[n] = true end
    local stale = {}
    for _, p in ipairs(vim.pack.get(nil, { info = false })) do
      if not keep[p.spec.name] then stale[#stale + 1] = p.spec.name end
    end
    if #stale == 0 then
      vim.notify("Nothing to clean")
      return
    end
    vim.ui.select({ "yes", "no" }, { prompt = "Delete " .. table.concat(stale, ", ") .. "?" },
      function(choice)
        if choice == "yes" then
          vim.pack.del(stale, { force = true })
          vim.notify("Removed " .. #stale .. " plugin(s)")
        end
      end)
  end, { desc = "Remove plugins no longer in the spec list" })
end

return M
