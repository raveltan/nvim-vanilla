-- URL string -> routing module. Cursor on a route like `/messages/thread/${id}`
-- walks the Angular route tree from the app root, following loadChildren across
-- files, and lands on the matching `path:` line in the deepest routing module.
--
-- Facts the walk relies on (standard Angular conventions; verified in the GAF webapp):
--   * baseUrl is `src`, so a bare/aliased import specifier resolves to
--     `<src>/<specifier>`; `./` and `../` resolve against the importing file.
--   * loadChildren points at a `*.module.ts`, whose sibling
--     `*-routing.module.ts` holds the routes via `RouterModule.forChild(<id>)`.
--   * Every routing file declares `const <id>: Routes = [ ... ]`.
-- Limits (best-effort fallback to the deepest match / wildcard): custom
-- `matcher:` routes, `redirectTo` chains.
local search = require("gaf.angular.search")
local ts = require("gaf.angular.ts")

local M = {}

-- Sentinel marking a `${...}` interpolation -- treated as a param segment.
local PARAM = "\1"

local function seg_is_param(s)
  return s:find(PARAM, 1, true) ~= nil
end

local function split_path(p)
  local t = {}
  for s in p:gmatch("[^/]+") do
    t[#t + 1] = s
  end
  return t
end

-- Does `parts` (a route path split on /) match the front of `segs`?
-- Returns consumed-segment count and a quality score, or nil. Empty `''` and
-- `**` paths are handled by the caller, not here. A dynamic `${...}` segment is
-- only matched against a route `:param` (never a literal -- we won't guess that
-- a runtime value equals a specific literal path).
local function match_path(parts, segs)
  if #parts == 0 or parts[1] == "**" or #parts > #segs then
    return nil
  end
  local quality = 0
  for i = 1, #parts do
    local pp, sg = parts[i], segs[i]
    local pp_param, sg_param = pp:sub(1, 1) == ":", seg_is_param(sg)
    if pp_param and sg_param then
      quality = quality + 5 -- param aligns with dynamic value: ideal
    elseif pp_param then
      quality = quality + 3 -- route :param accepts a literal value
    elseif sg_param then
      return nil -- literal route vs dynamic segment: don't guess
    elseif pp == sg then
      quality = quality + 10 -- literal exact
    else
      return nil
    end
  end
  return #parts, quality
end

-- ── loading routing files ──────────────────────────────────────────────────

-- Resolve a module specifier to an existing .ts file. Relative specifiers
-- resolve against `from_dir`; everything else against the webapp `src` root.
local function resolve_module(spec, from_dir, src_root)
  local base
  if spec:match("^%.%.?/") then
    base = vim.fs.normalize(from_dir .. "/" .. spec)
  else
    base = src_root .. "/" .. spec
  end
  for _, c in ipairs({ base .. ".ts", base .. "/index.ts" }) do
    if vim.uv.fs_stat(c) then return c end
  end
end

-- Routing module for a loaded NgModule file: prefer the universal sibling
-- naming (foo.module.ts -> foo-routing.module.ts), else parse its imports.
local function routing_module_for(mod_file, src_root)
  local sibling = mod_file:gsub("%.module%.ts$", "-routing.module.ts")
  if sibling ~= mod_file and vim.uv.fs_stat(sibling) then
    return sibling
  end
  for _, line in ipairs(vim.fn.readfile(mod_file)) do
    local spec = line:match("from%s+['\"]([^'\"]+routing%.module)['\"]")
    if spec then
      local f = resolve_module(spec, vim.fs.dirname(mod_file), src_root)
      if f then return f end
    end
  end
end

-- Find the routes array node: the identifier/array passed to forChild/forRoot,
-- chasing an identifier to its `const <id> = [ ... ]` declaration.
local function find_call_arg(node, src)
  if node:type() == "call_expression" then
    local fn = node:field("function")[1]
    if fn and fn:type() == "member_expression" then
      local prop = fn:field("property")[1]
      local name = prop and vim.treesitter.get_node_text(prop, src)
      if name == "forChild" or name == "forRoot" then
        local args = node:field("arguments")[1]
        if args then return args:named_child(0) end
      end
    end
  end
  for c in node:iter_children() do
    local r = find_call_arg(c, src)
    if r then return r end
  end
end

local function find_var_array(node, src, name)
  if node:type() == "variable_declarator" then
    local n = node:field("name")[1]
    if n and vim.treesitter.get_node_text(n, src) == name then
      local v = node:field("value")[1]
      if v and v:type() == "as_expression" then v = v:named_child(0) end
      if v and v:type() == "array" then return v end
    end
  end
  for c in node:iter_children() do
    local r = find_var_array(c, src, name)
    if r then return r end
  end
end

local function find_routes_array(root, src)
  local arg = find_call_arg(root, src)
  if not arg then return nil end
  if arg:type() == "as_expression" then arg = arg:named_child(0) end
  if not arg then return nil end
  if arg:type() == "array" then return arg end
  if arg:type() == "identifier" then
    return find_var_array(root, src, vim.treesitter.get_node_text(arg, src))
  end
end

-- Read + parse a routing file off disk. Returns path, source string,
-- routes-array node -- or nil.
local function load_routes_file(path)
  if not vim.uv.fs_stat(path) then return nil end
  local root, src = ts.parse_file(path)
  if not root then return nil end
  local arr = find_routes_array(root, src)
  if not arr then return nil end
  return path, src, arr
end

-- Follow a loadChildren specifier to the target module's routing file.
local function open_loaded(spec, from_file, src_root)
  local mod = resolve_module(spec, vim.fs.dirname(from_file), src_root)
  if not mod then return nil end
  local routing = routing_module_for(mod, src_root)
  if not routing then return nil end
  return load_routes_file(routing)
end

-- ── walking the route tree ─────────────────────────────────────────────────

local function unwrap(node)
  return node:type() == "as_expression" and node:named_child(0) or node
end

-- One route object -> { path, pos = {lnum,col}, children = <array|nil>,
-- load_spec = <string|nil> }. pos points at the `path:` value (else the object).
local function parse_route_object(obj, src)
  local r = {}
  for pair in obj:iter_children() do
    if pair:type() == "pair" then
      local key, val = pair:field("key")[1], pair:field("value")[1]
      local kname = key and vim.treesitter.get_node_text(key, src):gsub("['\"]", "")
      if kname == "path" and val and val:type() == "string" then
        r.path = vim.treesitter.get_node_text(val, src):gsub("^['\"]", ""):gsub("['\"]$", "")
        local row, col = val:range()
        r.pos = { row + 1, col }
      elseif kname == "children" and val then
        local v = unwrap(val)
        if v:type() == "array" then r.children = v end
      elseif kname == "loadChildren" and val then
        r.load_spec = vim.treesitter.get_node_text(val, src):match("import%(%s*['\"]([^'\"]+)['\"]")
      end
    end
  end
  if not r.pos then
    local row, col = obj:range()
    r.pos = { row + 1, col }
  end
  return r
end

local function parse_routes_in_array(arr, src)
  local routes = {}
  for obj in arr:iter_children() do
    if obj:type() == "object" then
      routes[#routes + 1] = parse_route_object(obj, src)
    end
  end
  return routes
end

-- Entry route of a routes list: the empty-path one, else the first.
local function entry_landing(routes, file)
  local empty, first
  for _, r in ipairs(routes) do
    first = first or r
    if r.path == "" then
      empty = r
      break
    end
  end
  local r = empty or first
  return r and { file = file, lnum = r.pos[1], col = r.pos[2] } or nil
end

-- Recursive descent: match `segs` against the routes in `arr` (from `file`),
-- crossing into lazy-loaded routing modules as needed. Returns the landing
-- { file, lnum, col, wildcard? } or nil.
local function resolve(arr, src, file, segs, src_root, depth)
  if depth > 40 then return nil end
  local routes = parse_routes_in_array(arr, src)

  if #segs == 0 then -- exhausted: land on this file's entry route
    return entry_landing(routes, file)
  end

  -- 1. best direct (non-empty, non-wildcard) match: more segments first, then
  -- match quality (literal > param). consumed dominates so a longer match always
  -- wins; quality (already weighted in match_path) only breaks ties.
  local best, best_score
  for _, r in ipairs(routes) do
    if r.path and r.path ~= "" then
      local consumed, quality = match_path(split_path(r.path), segs)
      if consumed then
        local score = consumed * 1000 + (quality or 0)
        if not best or score > best_score then
          best, best_score = { r = r, consumed = consumed }, score
        end
      end
    end
  end
  if best then
    local r = best.r
    local rest = {}
    for i = best.consumed + 1, #segs do rest[#rest + 1] = segs[i] end
    local here = { file = file, lnum = r.pos[1], col = r.pos[2] }
    if r.load_spec then
      local cf, cs, ca = open_loaded(r.load_spec, file, src_root)
      if not ca then return here end
      -- Match deeper; else land on the loaded module's entry, not this line.
      return resolve(ca, cs, cf, rest, src_root, depth + 1)
        or entry_landing(parse_routes_in_array(ca, cs), cf)
        or here
    elseif r.children and #rest > 0 then
      return resolve(r.children, src, file, rest, src_root, depth + 1) or here
    end
    return here
  end

  -- 2. transparent empty-path wrappers.
  for _, r in ipairs(routes) do
    if r.path == "" and r.children then
      local res = resolve(r.children, src, file, segs, src_root, depth + 1)
      if res then return res end
    end
  end

  -- 3. wildcard catch-all (last resort -- usually a 404/PHP redirect).
  for _, r in ipairs(routes) do
    if r.path == "**" then
      return { file = file, lnum = r.pos[1], col = r.pos[2], wildcard = true }
    end
  end
end

-- URL segments from the string/template under the cursor, with `${...}`
-- collapsed to a param sentinel and query/fragment stripped.
local function url_segments_under_cursor(buf)
  local node = vim.treesitter.get_node({ bufnr = buf })
  while node and node:type() ~= "string" and node:type() ~= "template_string" do
    node = node:parent()
  end
  if not node then return nil end
  local txt = vim.treesitter.get_node_text(node, buf)
  txt = txt:gsub("^[`'\"]", ""):gsub("[`'\"]$", "")
  txt = txt:gsub("[?#].*$", "")
  txt = txt:gsub("%$%b{}", PARAM)
  local segs = {}
  for s in txt:gmatch("[^/]+") do
    segs[#segs + 1] = s
  end
  return segs
end

-- Locate the webapp root app-routing module by walking up from `fname`.
-- Returns the app-routing path and the `src` dir (the import baseUrl), or nil.
-- Walks ancestors rather than slicing the path, so it works from any file in
-- the tree and across git worktrees (.../fl-gaf-worktree/Dxxxxx/webapp/...).
local function find_app_root(fname)
  for dir in vim.fs.parents(fname) do
    local cand = dir .. "/src/app/app-routing.module.ts"
    if vim.uv.fs_stat(cand) then
      return cand, dir .. "/src"
    end
  end
end

function M.goto_route()
  if vim.bo.filetype ~= "typescript" then
    search.notify("Not a TypeScript buffer", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local segs = url_segments_under_cursor(buf)
  if not segs or #segs == 0 then
    search.notify("Place the cursor on a URL/route string", vim.log.levels.WARN)
    return
  end
  local app_routing, src_root = find_app_root(vim.api.nvim_buf_get_name(buf))
  if not app_routing then
    search.notify("Could not find webapp/src/app/app-routing.module.ts above this file", vim.log.levels.WARN)
    return
  end
  local file, src, arr = load_routes_file(app_routing)
  if not arr then
    search.notify("Could not parse " .. app_routing, vim.log.levels.WARN)
    return
  end
  local res = resolve(arr, src, file, segs, src_root, 0)
  local pretty = "/" .. table.concat(segs, "/"):gsub(PARAM, ":param")
  if not res then
    search.notify("No route matched " .. pretty, vim.log.levels.WARN)
    return
  end
  if res.wildcard then
    search.notify("No exact route for " .. pretty .. " -- landed on wildcard/catch-all", vim.log.levels.WARN)
  end
  search.jump_to(res.file, res.lnum, res.col)
end

return M
