-- Minimal SCSS nesting resolver, just enough to rename BEM classes built by
-- `&`-suffix concatenation (.Header { &-main {} } defines Header-main) and to
-- cascade that rename through deeper nests (&-title under &-main). Not a parser.
-- Comments are stripped structurally, `#{...}` interpolation braces create
-- harmless phantom blocks, and selector groups are comma-split naively. Sites the
-- rename cannot rewrite safely come back as warnings, never guessed at.

local M = {}

local function rep_escape(str)
  return (str:gsub("%%", "%%%%"))
end

-- Block tree from buffer lines. A block carries raws (comma-split selector
-- strings, at-rules kept whole), the 1-based selector span sel_line..brace_line,
-- and children.
function M.parse(lines)
  local root = { children = {} }
  local stack = { root }
  local pending, pending_line = "", nil
  local in_comment = false

  for i, raw_line in ipairs(lines) do
    local line = raw_line
    if in_comment then
      local e = line:find("%*/")
      if e then
        line = string.rep(" ", e + 1) .. line:sub(e + 2)
        in_comment = false
      else
        line = ""
      end
    end
    while true do
      local s = line:find("/%*")
      if not s then break end
      local e = line:find("%*/", s + 2)
      if e then
        line = line:sub(1, s - 1) .. string.rep(" ", e + 2 - s) .. line:sub(e + 2)
      else
        line = line:sub(1, s - 1)
        in_comment = true
        break
      end
    end
    local lc = line:find("//", 1, true)
    if lc then line = line:sub(1, lc - 1) end

    for col = 1, #line do
      local ch = line:sub(col, col)
      if ch == "{" then
        local sel = vim.trim(pending)
        local blk = {
          raws = {}, children = {},
          sel_line = pending_line or i, brace_line = i,
        }
        if sel:sub(1, 1) == "@" then
          blk.raws[1] = sel
        else
          for piece in (sel .. ","):gmatch("%s*(.-)%s*,") do
            if piece ~= "" then blk.raws[#blk.raws + 1] = piece end
          end
        end
        table.insert(stack[#stack].children, blk)
        stack[#stack + 1] = blk
        pending, pending_line = "", nil
      elseif ch == "}" then
        if #stack > 1 then table.remove(stack) end
        pending, pending_line = "", nil
      elseif ch == ";" then
        pending, pending_line = "", nil
      else
        if pending == "" and ch:match("%S") then pending_line = i end
        pending = pending .. ch
      end
    end
    if pending ~= "" then pending = pending .. " " end
  end
  return root
end

-- Resolved selector strings for every block, pre-order. `overrides[blk][idx]`
-- substitutes a raw before resolving, so an overridden run can be diffed against
-- the plain one to learn which class names a rewrite would change. `resolved[idx]`
-- is one string per parent, or false for at-rules.
local function resolve(root, overrides)
  local out = {}
  local function walk(blk, parents)
    local mine = {}
    if blk.raws then
      local entry = { block = blk, parents = parents, resolved = {} }
      for idx, raw0 in ipairs(blk.raws) do
        local raw = overrides and overrides[blk] and overrides[blk][idx] or raw0
        if raw:sub(1, 1) == "@" then
          vim.list_extend(mine, parents)
          entry.resolved[idx] = false
        else
          local rs = {}
          if raw:find("&", 1, true) and #parents > 0 then
            for _, p in ipairs(parents) do
              rs[#rs + 1] = (raw:gsub("&", rep_escape(p)))
            end
          elseif #parents > 0 then
            for _, p in ipairs(parents) do
              rs[#rs + 1] = p .. " " .. raw
            end
          else
            rs[1] = raw
          end
          entry.resolved[idx] = rs
          vim.list_extend(mine, rs)
        end
      end
      out[#out + 1] = entry
    end
    for _, c in ipairs(blk.children) do
      walk(c, #mine > 0 and mine or parents)
    end
  end
  walk(root, {})
  return out
end

-- Overrides plus positional patches that rename class `old` to `new`. A raw is
-- either a literal `.old` mention, which the text pass handles, or a `&suffix`
-- site whose parent concatenation builds `old`. The second kind is only rewritable
-- when `new` keeps the parent class as its prefix, so `Header-main` to
-- `Header-primary` edits `&-main` into `&-primary`, while `Header-main` to
-- `Nav-main` cannot be expressed with `&` and is warned instead.
local function plan(root, old, new)
  local res = resolve(root)
  local dot_pat = "%." .. vim.pesc(old) .. "%f[^%w_%-]"
  local overrides, patches, warnings = {}, {}, {}
  local handled = false

  for _, e in ipairs(res) do
    for idx, raw in ipairs(e.block.raws) do
      if raw:sub(1, 1) ~= "@" then
        if raw:find(dot_pat) then
          overrides[e.block] = overrides[e.block] or {}
          overrides[e.block][idx] = raw:gsub(dot_pat, "." .. rep_escape(new))
          handled = true
        else
          local suffix = raw:match("^&([%w_%-]+)")
          if suffix then
            local parent_class, all_match = nil, true
            for _, p in ipairs(e.parents) do
              local P = p:match("%.([%w_%-]+)$")
              local built = P and (P .. suffix)
              if built == old then parent_class = P else all_match = false end
            end
            if parent_class then
              if not all_match then
                warnings[#warnings + 1] = ("line %d: `&%s` is shared by several parents and only some build .%s, so it was skipped"):format(e.block.sel_line, suffix, old)
              elseif new:sub(1, #parent_class) == parent_class and #new > #parent_class then
                local nsuf = new:sub(#parent_class + 1)
                overrides[e.block] = overrides[e.block] or {}
                overrides[e.block][idx] = "&" .. nsuf .. raw:sub(#suffix + 2)
                patches[#patches + 1] = { block = e.block, suffix = suffix, new_suffix = nsuf }
                handled = true
              else
                warnings[#warnings + 1] = ("line %d: `&%s` builds .%s by concatenation under .%s. '%s' drops that prefix, so restructure it manually"):format(e.block.sel_line, suffix, old, parent_class, new)
              end
            end
          end
        end
      end
    end
  end
  return overrides, patches, warnings, res, handled
end

-- Class-name rename map implied by the overrides. Resolving twice and diffing the
-- class tokens positionally is what makes deeper `&` nests cascade, so
-- Header-main-title follows Header-main and templates can be updated to match.
local function diff_map(root, overrides, res_old)
  local res_new = resolve(root, overrides)
  local map = {}
  for i = 1, #res_old do
    local eo, en = res_old[i], res_new[i]
    for idx, olds in pairs(eo.resolved) do
      local news = en.resolved[idx]
      if olds and news then
        for k = 1, #olds do
          if news[k] and olds[k] ~= news[k] then
            local oc, nc = {}, {}
            for c in olds[k]:gmatch("%.([%w_%-]+)") do oc[#oc + 1] = c end
            for c in news[k]:gmatch("%.([%w_%-]+)") do nc[#nc + 1] = c end
            for j = 1, math.min(#oc, #nc) do
              if oc[j] ~= nc[j] then map[oc[j]] = nc[j] end
            end
          end
        end
      end
    end
  end
  return map
end

-- Rename class `old` to `new` in scss `lines`. The returned map covers every class
-- the edit changes, `&` cascades included, so the caller can propagate it into
-- templates. handled=false means no definition site for `old` could be rewritten.
function M.rename(lines, old, new)
  local root = M.parse(lines)
  local overrides, patches, warnings, res, handled = plan(root, old, new)
  local map = diff_map(root, overrides, res)
  map[old] = new

  local out = {}
  for i, l in ipairs(lines) do out[i] = l end
  local changed = false

  for _, p in ipairs(patches) do
    local pat = "&" .. vim.pesc(p.suffix) .. "%f[^%w_%-]"
    for ln = p.block.sel_line, p.block.brace_line do
      local nl, n = out[ln]:gsub(pat, "&" .. rep_escape(p.new_suffix), 1)
      if n > 0 then
        out[ln] = nl
        changed = true
        break
      end
    end
  end
  for oc, nc in pairs(map) do
    local pat = "%." .. vim.pesc(oc) .. "%f[^%w_%-]"
    local rep = "." .. rep_escape(nc)
    for i, l in ipairs(out) do
      local nl, n = l:gsub(pat, rep)
      if n > 0 then
        out[i] = nl
        changed = true
      end
    end
  end
  return changed and out or nil, map, warnings, handled
end

-- Full class name built by the `&suffix` selector of the innermost block whose
-- selector span covers `row`, or nil. `suffix` comes from the caller's
-- token-under-cursor scan, so multi-selector lines pick the right one.
function M.amp_class_at(lines, row, suffix)
  local res = resolve(M.parse(lines))
  local best
  local raw_pat = "^&" .. vim.pesc(suffix) .. "%f[^%w_%-]"
  for _, e in ipairs(res) do
    local b = e.block
    if row >= b.sel_line and row <= b.brace_line then
      for _, raw in ipairs(b.raws) do
        if raw:find(raw_pat) and #e.parents > 0 then
          local P = e.parents[1]:match("%.([%w_%-]+)$")
          if P then best = P .. suffix end
        end
      end
    end
  end
  return best
end

return M
