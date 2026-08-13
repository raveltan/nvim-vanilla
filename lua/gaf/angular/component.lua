-- Reading a component file: its @Input/@Output members, its @Component facts,
-- and the import specifier other files should use to reach it. Everything here
-- parses files off disk (never a buffer) and is cached per file+mtime, so the
-- first completion on a fresh tag pays for the parse and the rest are table
-- reads.
local search = require("gaf.angular.search")
local patterns = require("gaf.angular.patterns")
local ts = require("gaf.angular.ts")

local M = {}

-- ── import specifiers ──────────────────────────────────────────────────────

-- Does the barrel `index_file` re-export `name`? Matches a named re-export
-- (`export { … name … }`), a direct `export enum name`, or any `export *`
-- (wildcard -- assume it may carry the symbol).
local function reexports(index_file, name)
  local txt = ts.read_file(index_file)
  if not txt then return false end
  for list in txt:gmatch("export%s*{(.-)}") do
    for tok in list:gmatch("[%w_]+") do
      if tok == name then return true end
    end
  end
  if txt:match("export%s*%*%s*from") then return true end
  if txt:match("export[^\n]-enum%s+" .. name .. "%f[%W]") then return true end
  return false
end

local spec_cache = {} -- file .. "\0" .. name -> spec or false

-- Public import specifier for the file defining `name`, assuming baseUrl = `src`
-- (verified in the GAF webapp). Prefers the nearest ancestor barrel (an
-- `index.ts` re-exporting `name`) so we import `@freelancer/ui/button`, not the
-- deep `@freelancer/ui/button/button-size`. Falls back to the file's own
-- src-relative path when no barrel re-exports it.
--
-- Memoized: the barrel walk reads an `index.ts` per ancestor directory, and the
-- NgModule planner asks the same question of every module that exports a class.
function M.import_spec(file, name)
  local key = file .. "\0" .. name
  local hit = spec_cache[key]
  if hit ~= nil then return hit or nil end

  local spec
  local src = search.src_root(file)
  if src then
    if file:match("/index%.ts$") then -- declared straight in a barrel
      spec = vim.fs.dirname(file):sub(#src + 2)
    else
      local dir = vim.fs.dirname(file)
      while dir and #dir > #src do
        local idx = dir .. "/index.ts"
        if vim.uv.fs_stat(idx) and reexports(idx, name) then
          spec = dir:sub(#src + 2)
          break
        end
        dir = vim.fs.dirname(dir)
      end
      spec = spec or (file:sub(#src + 2):gsub("%.ts$", ""))
    end
  end
  spec_cache[key] = spec or false
  return spec
end

-- Directory of `file` as an import-style path (`@freelancer/ui/button`), which
-- both labels a completion item and separates the several files that can define
-- one selector. Outside a src tree the bare directory name is the best label.
function M.dir_label(file)
  local src = search.src_root(file)
  local dir = vim.fs.dirname(file)
  if src and #dir > #src then return dir:sub(#src + 2) end
  return vim.fn.fnamemodify(file, ":h:t")
end

-- ── @Input/@Output members ─────────────────────────────────────────────────

-- Strip comment markers from a doc comment's raw text -> clean markdown-ish body.
-- Handles `/** … */` / `/* … */` (drops the delimiters and per-line leading `*`)
-- and `//` line comments.
local function clean_comment(text)
  text = text:gsub("^/%*%*?", ""):gsub("%*/%s*$", "")
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("^%s*%*+%s?", "") -- block-comment continuation `*`
    line = line:gsub("^%s*//+%s?", "") -- line comment
    lines[#lines + 1] = line
  end
  return vim.trim(table.concat(lines, "\n"))
end

-- The doc comment attached to `member`: the contiguous `comment` siblings
-- collected in `comments`, but only when the block sits directly above the
-- member (a gap means it documents something else / is a stray comment).
local function leading_doc(comments, member, src)
  if #comments == 0 then return nil end
  local msrow = member:range()
  local _, _, lerow = comments[#comments]:range()
  if msrow - lerow > 1 then return nil end -- not adjacent
  local parts = {}
  for _, c in ipairs(comments) do
    parts[#parts + 1] = clean_comment(vim.treesitter.get_node_text(c, src))
  end
  local doc = vim.trim(table.concat(parts, "\n"))
  return doc ~= "" and doc or nil
end

-- Type of an @Input setter's parameter: `set x(v: T)` -> "T".
local function setter_param_type(method, src)
  local params = method:field("parameters")[1]
  local p = params and params:named_child(0)
  if not p then return nil end
  for c in p:iter_children() do
    if c:type() == "type_annotation" then
      return ts.strip_annotation(vim.treesitter.get_node_text(c, src))
    end
  end
end

-- Classify one class member -> { name, prop, kind = input|output|model, type,
-- doc } or nil. `name` is the template binding name (alias if any), `prop` the
-- field, `doc` the cleaned leading comment (or nil). `pending` holds decorator
-- nodes that preceded the member as siblings (how the TS parser attaches a
-- decorator to a setter method, vs a field where it's a child).
local function member_input(member, pending, doc, src)
  local mt = member:type()
  if mt ~= "public_field_definition" and mt ~= "method_definition" then return nil end
  local nn = member:field("name")[1]
  if not nn then return nil end
  local prop = vim.treesitter.get_node_text(nn, src)

  local decs = {}
  for _, d in ipairs(pending) do decs[#decs + 1] = d end
  for c in member:iter_children() do
    if c:type() == "decorator" then decs[#decs + 1] = c end
  end

  -- 1. classic @Input()/@Output() decorator.
  for _, d in ipairs(decs) do
    local dn, call = ts.decorator_call(d, src)
    if dn == "Input" or dn == "Output" then
      local kind = dn == "Input" and "input" or "output"
      local ty
      if kind == "input" then
        if mt == "method_definition" then
          ty = setter_param_type(member, src)
        else
          local tn = member:field("type")[1]
          ty = tn and ts.strip_annotation(vim.treesitter.get_node_text(tn, src))
        end
      else -- output: the EventEmitter<T> payload from the initialiser
        local v = member:field("value")[1]
        ty = v and ts.angle_generic(vim.treesitter.get_node_text(v, src))
      end
      return { name = ts.first_string_arg(call, src) or prop, prop = prop, kind = kind, type = ty, doc = doc }
    end
  end

  -- 2. signal API: `x = input<T>() / input.required<T>() / model<T>() / output<T>()`.
  if mt == "public_field_definition" then
    local v = member:field("value")[1]
    if v and v:type() == "call_expression" then
      local vt = vim.treesitter.get_node_text(v, src)
      local base = (vt:match("^([%w_%.]+)") or ""):match("^([%w_]+)")
      local kind = base == "input" and "input"
        or base == "model" and "model"
        or base == "output" and "output"
        or nil
      if kind then
        local alias = vt:match("alias%s*:%s*['\"]([^'\"]+)")
        return { name = alias or prop, prop = prop, kind = kind, type = ts.angle_generic(vt), doc = doc }
      end
    end
  end
end

-- Every @Input/@Output/signal member declared in the parsed file, deduped by
-- binding name. Scans all classes in the file (component files hold one class in
-- practice, so cross-class mixing is moot).
local function scan_inputs(root, src)
  local out, seen = {}, {}
  ts.each_node(root, "class_body", function(body)
    local pending, comments = {}, {}
    for member in body:iter_children() do
      local mt = member:type()
      if mt == "decorator" then
        pending[#pending + 1] = member
      elseif mt == "comment" then
        comments[#comments + 1] = member
      else
        local r = member_input(member, pending, leading_doc(comments, member, src), src)
        if r and not seen[r.name] then
          seen[r.name] = true
          out[#out + 1] = r
        end
        if mt == "public_field_definition" or mt == "method_definition" then
          pending, comments = {}, {}
        end
      end
    end
  end)
  return out
end

-- ── @Component facts ───────────────────────────────────────────────────────

local function scan_component(root, src, file, input_count)
  local info
  ts.each_node(root, "decorator", function(dec)
    if info then return end -- first @Component wins (files hold one in practice)
    local dname, call = ts.decorator_call(dec, src)
    if dname ~= "Component" or not call then return end
    local cls = ts.decorated_class(dec)
    local nn = cls and cls:field("name")[1]
    if not nn then return end
    local class = vim.treesitter.get_node_text(nn, src)

    local obj = ts.decorator_object(call)
    local standalone, selector
    if obj then
      -- Angular 19 treats an absent `standalone` as true, but record the absence
      -- as nil rather than assuming: on an older component it means NgModule.
      local raw = ts.decorator_option(obj, "standalone", src)
      if raw then standalone = raw == "true" end
      local sel = ts.decorator_option(obj, "selector", src)
      selector = sel and (sel:gsub("['\"]", ""))
    end
    info = {
      class = class,
      standalone = standalone,
      spec = M.import_spec(file, class),
      selector = selector,
      inputs = input_count,
    }
  end)
  return info
end

-- ── the per-file cache ─────────────────────────────────────────────────────

local cache = {} -- file -> { mtime = <sec>, inputs = { ... }, info = <table|false> }

-- One read + one parse answers both questions the completion asks of a file, so
-- they are cached together. Misses are cached too: a non-component `.ts` is a
-- stable nil.
local function facts(file)
  local st = vim.uv.fs_stat(file)
  if not st then return nil end
  local c = cache[file]
  if c and c.mtime == st.mtime.sec then return c end

  local root, src = ts.parse_file(file)
  local entry = { mtime = st.mtime.sec, inputs = {}, info = false }
  if root then
    entry.inputs = scan_inputs(root, src)
    entry.info = scan_component(root, src, file, #entry.inputs) or false
  end
  cache[file] = entry
  return entry
end

-- Member list for a component file (empty when it has none / doesn't parse).
function M.inputs(file)
  local f = facts(file)
  return f and f.inputs or {}
end

-- Component metadata -- { class, standalone, spec, selector, inputs } -- the
-- documentation body behind a tag completion item, or nil.
function M.info(file)
  local f = facts(file)
  return f and (f.info or nil) or nil
end

-- ── enums + literal unions (value completion) ──────────────────────────────

-- Member names of `enum <name>` declared in `file`.
local function enum_members(file, name)
  local root, src = ts.parse_file(file)
  if not root then return {} end
  local out = {}
  ts.each_node(root, "enum_declaration", function(ed)
    local id = ts.child_by_type(ed, "identifier")
    if not id or vim.treesitter.get_node_text(id, src) ~= name then return end
    local body = ts.child_by_type(ed, "enum_body")
    if not body then return end
    for c in body:iter_children() do
      local pid = c:type() == "property_identifier" and c
        or (c:type() == "enum_assignment" and ts.child_by_type(c, "property_identifier"))
      if pid then out[#out + 1] = vim.treesitter.get_node_text(pid, src) end
    end
  end)
  return out
end

-- RHS of `export type <name> = …` in `file`, or nil.
local function type_alias_value(file, name)
  local root, src = ts.parse_file(file)
  if not root then return nil end
  local out
  ts.each_node(root, "type_alias_declaration", function(n)
    local nm, val = n:field("name")[1], n:field("value")[1]
    if nm and val and vim.treesitter.get_node_text(nm, src) == name then
      out = vim.treesitter.get_node_text(val, src)
    end
  end)
  return out
end

-- Reduce a type annotation to a lone named type, dropping ` | null`,
-- ` | undefined`, `readonly`, and a trailing `[]` -- so `ButtonSize | null` and
-- `readonly ButtonSize[]` both yield `ButtonSize`. nil when what remains isn't a
-- single PascalCase identifier.
function M.enum_name_of(t)
  local core = t:gsub("%s*|%s*null", ""):gsub("%s*|%s*undefined", ""):gsub("readonly%s+", ""):gsub("%[%]", "")
  core = vim.trim(core)
  return core:match("^%u[%w_]*$") and core or nil
end

-- Classify an input's declared type for value completion:
--   { kind = "enum",  name = "ButtonSize" }              (bare/nullable enum)
--   { kind = "union", values = { "'a'", "'b'" } }        (string/number literals)
-- or nil. A union with any non-literal, non-null member is not offered.
function M.classify_type(t)
  local name = M.enum_name_of(t)
  if name then return { kind = "enum", name = name } end
  local vals, pure, has = {}, true, false
  for part in t:gmatch("[^|]+") do
    part = vim.trim(part)
    if part == "" or part == "null" or part == "undefined" then -- ignore
    elseif part:match("^'[^']*'$") or part:match('^"[^"]*"$') or part:match("^%-?%d+%.?%d*$") then
      vals[#vals + 1] = part
      has = true
    else
      pure = false
    end
  end
  if has and pure then return { kind = "union", values = vals } end
end

local type_cache = {} -- type name -> resolved def (enum|union) or false (neither)

-- Resolve a named type (bare or nullable) to its exported definition, for value
-- completion. `cb` gets one of, or nil (cached per normalized name, misses too):
--   { kind = "enum",  name, file, spec, members }   -- `export enum X`
--   { kind = "union", name, file, spec, values }    -- `export type X = 'a'|'b'`
-- A string-valued enum in Angular is often modelled as a string-literal type
-- alias, not an `enum` -- both resolve here so both drive completion.
function M.resolve_type(type_name, cb)
  local core = M.enum_name_of(type_name)
  if not core then return cb(nil) end
  local cached = type_cache[core]
  if cached ~= nil then return cb(cached or nil) end

  search.rg_run(patterns.exported_type(core), { search.buf_root(0) }, function(items)
    local hit = items[1]
    local res
    if hit and hit.line and hit.line:match("enum%s+" .. core .. "%f[%W]") then
      res = { kind = "enum", name = core, file = hit.file,
        spec = M.import_spec(hit.file, core), members = enum_members(hit.file, core) }
    elseif hit then
      local cls = M.classify_type(type_alias_value(hit.file, core) or "")
      if cls and cls.kind == "union" then
        res = { kind = "union", name = core, file = hit.file,
          spec = M.import_spec(hit.file, core), values = cls.values }
      end
    end
    type_cache[core] = res or false
    cb(res)
  end)
end

-- Enum-only view of resolve_type (for `Enum.` member completion + attr seeding).
function M.resolve_enum(type_name, cb)
  M.resolve_type(type_name, function(t) cb(t and t.kind == "enum" and t or nil) end)
end

return M
