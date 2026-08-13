-- Repo-wide index of `@NgModule` declarations, answering the two questions the
-- NgModule half of tag completion has to ask: which module DECLARES a component
-- (that's the module whose `imports:` has to grow for a tag to resolve), and
-- which modules EXPORT it (that's the symbol to add there). 3837 of the GAF
-- webapp's components are `standalone: false`, so this is the majority path.
--
-- Only DIRECT exports are recorded -- no walk of the module graph. It costs
-- nothing in practice: the aggregate modules a consumer actually reaches for
-- re-export their contents directly (`@freelancer/ui/ui.module` lists all 147 of
-- its components in `exports`), so a direct index already names them.
--
-- The scan is a bracket-balanced Lua pass over the file text, not treesitter.
-- Measured over the webapp's 1976 `@NgModule` files (2.3 MB): treesitter parse +
-- traversal 350 ms, this 26 ms, with the two agreeing on the arrays of all 1982
-- modules they find. Treesitter would have fit the budget too, but a repo-wide
-- index is exactly the thing a user waits on, and nothing here needs a real
-- parse: the three arrays hold bare identifiers, and comments/strings are the
-- only structure that can hide a bracket (ui.module.ts keeps a JSDoc block
-- carrying `[attr.disabled]` inside its `imports`), which the lexer below steps
-- over. What we give up is the type system's view of an `imports:` that isn't an
-- array literal -- a spread or a shared const reads as "no imports" here, the
-- same as it does to the edit builder, which refuses to rewrite one.
--
-- The index is:
--   modules   = file -> { <record>, ... }
--   declarer  = ComponentClass -> <record>
--   exporters = ComponentClass -> { <record>, ... }
-- A record is { module_class, file, declarations, exports, imports } -- the last
-- three being identifier lists. Records are shared by all three tables, so a
-- consumer may memoize derived data (edits.lua caches `spec`) on them.
--
-- `rg_run` is injected by the caller rather than required back out of it, so the
-- rg invocation (type filters, async plumbing) lives in one place.
local root_cache = require("gaf.angular.root_cache")

local M = {}

-- The `@NgModule` keys that decide whether a tag resolves. `providers`,
-- `bootstrap`, `schemas` and `entryComponents` never do, so they're skipped.
local KEYS = { declarations = true, exports = true, imports = true }

-- ── text lexer ─────────────────────────────────────────────────────────────

-- Index just past the string or comment starting at `i`, or nil when `i` isn't
-- the start of one. Both scanners below step over these spans so that a `,`,
-- `]` or `(` living inside a comment or a quoted string can't be mistaken for
-- structure. A template literal is skipped whole, `${}` and all -- module option
-- arrays don't hold interpolations, and treating one as opaque only ever makes
-- us miss an entry, never invent one.
local function skip_span(s, i)
  local c = s:sub(i, i)
  if c == "'" or c == '"' or c == "`" then
    local j = i + 1
    while j <= #s do
      local d = s:sub(j, j)
      if d == "\\" then
        j = j + 2
      elseif d == c then
        return j + 1
      else
        j = j + 1
      end
    end
    return #s + 1
  end
  if c == "/" then
    local d = s:sub(i + 1, i + 1)
    if d == "/" then return (s:find("\n", i + 2, true) or #s) + 1 end
    if d == "*" then
      local e = s:find("*/", i + 2, true)
      return e and e + 2 or #s + 1
    end
  end
end

-- Index of the `close` bracket ending the run that starts at `i`, honouring
-- nesting; nil when the text runs out or a different bracket closes it first.
local function find_close(s, i, close)
  local depth = 0
  while i <= #s do
    local j = skip_span(s, i)
    if j then
      i = j
    else
      local c = s:sub(i, i)
      if c == "(" or c == "[" or c == "{" then
        depth = depth + 1
      elseif c == ")" or c == "]" or c == "}" then
        if depth == 0 then return c == close and i or nil end
        depth = depth - 1
      end
      i = i + 1
    end
  end
end

-- Drop the leading whitespace and comments an entry may carry, so the head
-- identifier is what the pattern below sees. ui.module.ts writes a FIXME block
-- above `ReactiveFormsModule.withConfig(...)`; app.server.module.ts a `//` note
-- above `AppModule`.
local function strip_lead(piece)
  piece = piece:gsub("^%s+", "")
  while piece:sub(1, 1) == "/" do
    local j = skip_span(piece, 1)
    if not j then break end
    piece = piece:sub(j):gsub("^%s+", "")
  end
  return piece
end

-- Head identifier of every top-level entry in an array body: `Foo`,
-- `Foo.forRoot(x)` and `Foo.withConfig({ a: 1 })` all yield `Foo`, which is the
-- name a consumer writes in its own `imports`.
local function entry_heads(body)
  local out, start, depth, i = {}, 1, 0, 1
  local function push(stop)
    local id = strip_lead(body:sub(start, stop)):match("^([%a_$][%w_$]*)")
    if id then out[#out + 1] = id end
  end
  while i <= #body do
    local j = skip_span(body, i)
    if j then
      i = j
    else
      local c = body:sub(i, i)
      if c == "(" or c == "[" or c == "{" then
        depth = depth + 1
      elseif c == ")" or c == "]" or c == "}" then
        depth = depth - 1
      elseif c == "," and depth == 0 then
        push(i - 1)
        start = i + 1
      end
      i = i + 1
    end
  end
  push(#body)
  return out
end

-- The three arrays of one decorator options object, spanning [from, to].
-- A key whose value isn't an array literal is left empty -- the same view the
-- edit builder takes of it.
local function scan_options(src, from, to)
  local out = { declarations = {}, exports = {}, imports = {} }
  local i, depth = from, 0
  while i <= to do
    local j = skip_span(src, i)
    if j then
      i = j
    else
      local c = src:sub(i, i)
      if c == "(" or c == "[" or c == "{" then
        depth = depth + 1
        i = i + 1
      elseif c == ")" or c == "]" or c == "}" then
        depth = depth - 1
        i = i + 1
      else
        local key, open = src:match("^([%a_$][%w_$]*)%s*:%s*()%[", i)
        local close = depth == 0 and key and KEYS[key] and find_close(src, open + 1, "]")
        if close then
          out[key] = entry_heads(src:sub(open + 1, close - 1))
          i = close + 1 -- the array's brackets never touched `depth`
        else
          i = i + 1
        end
      end
    end
  end
  return out
end

-- Every `@NgModule({ ... })` in `src`, as records missing only `file`.
local function scan(src)
  local mods, at = {}, 1
  while true do
    local _, paren = src:find("@NgModule%s*%(", at)
    if not paren then break end
    local obj = src:match("^%s*()%{", paren + 1)
    local obj_end = obj and find_close(src, obj + 1, "}")
    if not obj_end then break end
    -- The decorated class is the next `class X` after the decorator: the TS
    -- grammar allows `export`/`abstract` in between but nothing that declares
    -- another class.
    local class = src:match("class%s+([%w_$]+)", obj_end)
    if class then
      local m = scan_options(src, obj + 1, obj_end - 1)
      m.module_class = class
      mods[#mods + 1] = m
    end
    at = obj_end + 1
  end
  return mods
end

-- ── index assembly ─────────────────────────────────────────────────────────

local function read(file)
  local fd = io.open(file, "r")
  if not fd then return nil end
  local src = fd:read("*a")
  fd:close()
  return src
end

-- Scan `file` into `idx`. Returns whether it contributed any module.
local function add_file(idx, file)
  local src = read(file)
  if not src then return false end
  local recs = scan(src)
  if #recs == 0 then return false end
  idx.modules[file] = recs
  for _, m in ipairs(recs) do
    m.file = file
    -- First declarer wins: Angular allows exactly one module to declare a
    -- component, so a second hit is a duplicated/stale file rather than a real
    -- choice, and picking the first keeps the answer stable.
    for _, d in ipairs(m.declarations) do
      if not idx.declarer[d] then idx.declarer[d] = m end
    end
    for _, e in ipairs(m.exports) do
      local list = idx.exporters[e]
      if not list then
        list = {}
        idx.exporters[e] = list
      end
      list[#list + 1] = m
    end
  end
  return true
end

-- One rg naming every file with an `@NgModule`, then a read + scan of each.
-- Always rebuilds; callers that want the cached index use M.get.
function M.build(root, rg_run, cb)
  rg_run({ "@NgModule\\b" }, { root }, function(items)
    local files, seen = {}, {}
    for _, it in ipairs(items) do
      if not seen[it.file] then
        seen[it.file] = true
        files[#files + 1] = it.file
      end
    end
    local idx = { modules = {}, declarer = {}, exporters = {} }
    for _, f in ipairs(files) do
      add_file(idx, f)
    end
    cb(idx)
  end)
end

local cache = root_cache.new(M.build)

M.revision = cache.revision
M.get = cache.get
M.invalidate = cache.invalidate

-- Re-scan one file after a write and patch it in. Never builds: an unindexed
-- root stays unindexed until a lookup asks for it. Dropping the file's
-- `declarer` entries can't restore a duplicate declaration that this file had
-- shadowed -- pathological, and :AngularReindex settles it.
function M.update_file(root, file)
  local idx = cache.peek(root)
  if not idx or not root_cache.tracks(root, file) then return end

  local had = idx.modules[file] ~= nil
  idx.modules[file] = nil
  for cls, m in pairs(idx.declarer) do
    if m.file == file then idx.declarer[cls] = nil end
  end
  for cls, list in pairs(idx.exporters) do
    for i = #list, 1, -1 do
      if list[i].file == file then table.remove(list, i) end
    end
    if #list == 0 then idx.exporters[cls] = nil end
  end

  local has = add_file(idx, file)
  -- Most saved `.ts` files hold no `@NgModule` at all; leaving the revision
  -- alone then keeps any derived view valid across those saves.
  if had or has then cache.bump(root) end
end

return M
