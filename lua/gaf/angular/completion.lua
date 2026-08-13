-- The data behind inline-template completion. Four questions, asked in this
-- order by the source that renders them:
--
--   tag_completions    `<fl-bu▏`            -> every component in the repo
--   enum_members       `[x]="Size.▏"`       -> that enum's members
--   value_completions  `[x]="▏"`            -> the values the input's type takes
--   inputs             `<app-foo ▏`         -> that component's @Input/@Output
--
-- The first comes from a repo-wide index (nothing under the cursor to rg for);
-- the rest resolve the tag under the cursor to its file, cached per selector, so
-- only the first hit on a fresh tag pays an rg.
local component = require("gaf.angular.component")
local context = require("gaf.angular.context")
local patterns = require("gaf.angular.patterns")
local search = require("gaf.angular.search")
local selector_index = require("gaf.angular.selector_index")

local M = {}

local sel_file_cache = {} -- selector -> component file path, or false (no def)

local function is_typescript(buf)
  return vim.bo[buf].filetype == "typescript"
end

-- Resolve the component tag under the cursor to its member list + meta, with no
-- value-context gate. Async only on a selector cache miss.
local function tag_inputs(cb)
  local buf = vim.api.nvim_get_current_buf()
  if not is_typescript(buf) then return cb(nil) end
  local tag = context.enclosing_tag_name(buf)
  if not tag or not tag:find("%-") then return cb(nil) end -- native el / none

  local cached = sel_file_cache[tag]
  if cached ~= nil then
    if not cached then return cb(nil) end
    return cb(component.inputs(cached), { tag = tag, file = cached })
  end

  search.rg_run(patterns.selector(tag), { search.buf_root(buf) }, function(defs)
    local file = defs[1] and defs[1].file
    sel_file_cache[tag] = file or false
    if not file then return cb(nil) end
    cb(component.inputs(file), { tag = tag, file = file })
  end)
end

-- Attribute-NAME completion: the component's inputs/outputs. Suppressed once the
-- cursor is inside a quoted value, where a value expression belongs instead.
function M.inputs(cb)
  if context.in_attr_value(vim.api.nvim_get_current_buf()) then return cb(nil) end
  tag_inputs(cb)
end

-- Attribute-VALUE completion: when the cursor is inside a component input's value
-- and that input's type is an enum or a string/number-literal union, call
-- `cb(spec, meta)` where spec is { kind="enum", enum, en } or
-- { kind="union", values, is_binding }; else `cb(nil)`.
function M.value_completions(cb)
  local buf = vim.api.nvim_get_current_buf()
  if not is_typescript(buf) then return cb(nil) end
  if not context.in_attr_value(buf) then return cb(nil) end
  local attr, is_binding = context.value_attr(buf)
  if not attr then return cb(nil) end
  tag_inputs(function(inputs, meta)
    if not inputs then return cb(nil) end
    local input
    for _, it in ipairs(inputs) do
      if it.name == attr then input = it break end
    end
    if not input or not input.type then return cb(nil) end
    local cls = component.classify_type(input.type)
    if not cls then return cb(nil) end
    if cls.kind == "union" then -- literal union written inline in the annotation
      return cb({ kind = "union", values = cls.values, is_binding = is_binding }, meta)
    end
    -- Named type: resolve to an enum (members) or a type-alias literal union.
    component.resolve_type(cls.name, function(t)
      if not t then return cb(nil) end
      if t.kind == "enum" then
        if #t.members == 0 then return cb(nil) end
        cb({ kind = "enum", enum = t.name, en = t }, meta)
      else
        cb({ kind = "union", values = t.values, is_binding = is_binding }, meta)
      end
    end)
  end)
end

-- Enum-member completion inside a template: when the cursor sits right after
-- `SomeEnum.` in an inline template and `SomeEnum` resolves to an exported enum,
-- call `cb(members, name, enumInfo)`; else `cb(nil)`. Gated to templates so it
-- never doubles up on tsserver, which completes enum members itself in real TS
-- code (and treats the template as an opaque string, offering nothing there).
function M.enum_members(cb)
  local buf = vim.api.nvim_get_current_buf()
  if not is_typescript(buf) then return cb(nil) end
  if not context.in_template(buf) then return cb(nil) end
  local enum = context.enum_prefix()
  if not enum then return cb(nil) end
  component.resolve_enum(enum, function(en)
    if not en or #en.members == 0 then return cb(nil) end
    cb(en.members, enum, en)
  end)
end

-- ── tag completion ─────────────────────────────────────────────────────────

local tag_items = {} -- root -> { rev = <selector_index revision>, items = { ... } }

-- Completion items for every element selector under `root`, sorted by selector
-- then dir. Rebuilt only when the index changes: labelling + sorting the ~4800
-- webapp selectors costs ~30ms, which a per-keystroke source must not repeat.
local function build_tag_items(root, idx)
  local items = {}
  for sel, entries in pairs(idx) do
    -- Free warm-up for attribute completion: it would otherwise spend an rg the
    -- first time each tag is completed on. Never overwrite -- an existing entry
    -- was resolved against the real cursor context.
    if sel_file_cache[sel] == nil then sel_file_cache[sel] = entries[1].file end
    for _, e in ipairs(entries) do
      items[#items + 1] = { selector = sel, file = e.file, dir = component.dir_label(e.file) }
    end
  end
  table.sort(items, function(a, b)
    if a.selector ~= b.selector then return a.selector < b.selector end
    return a.dir < b.dir
  end)
  tag_items[root] = { rev = selector_index.revision(root), items = items }
  return items
end

-- Tag-NAME completion data: `cb(items, { lt_col, prefix })` where items are
-- `{ selector, file, dir }` for every element selector in the repo, or `cb(nil)`
-- when the cursor isn't in tag-name position. `lt_col` is the 0-indexed column
-- of the `<`, so the source can replace the partial tag rather than append to it.
function M.tag_completions(cb)
  local buf = vim.api.nvim_get_current_buf()
  if not is_typescript(buf) then return cb(nil) end
  if not context.in_template(buf) or context.in_attr_value(buf) then return cb(nil) end
  -- A `<` used as a comparison in a binding expression (`[x]="a <b"`) still
  -- matches -- harmless, since nothing there fuzzy-matches a selector.
  local lt_col, prefix = context.tag_prefix()
  if not lt_col then return cb(nil) end
  local meta = { lt_col = lt_col, prefix = prefix }
  -- A bare `<` is also every `<div` and `<ng-container` in the file, and a
  -- 4800-item menu is no use at that width, so the consumer throws it away and
  -- asks again after the first letter. Answer "tag position, nothing yet"
  -- without touching the index: otherwise the first `<` typed in any template
  -- pays for the repo-wide rg on results nobody reads.
  if prefix == "" then return cb({}, meta) end

  local root = search.buf_root(buf)
  selector_index.get(root, search.rg_run, function(idx)
    local cached = tag_items[root]
    local items = (cached and cached.rev == selector_index.revision(root))
      and cached.items
      or build_tag_items(root, idx)
    cb(items, meta)
  end)
end

return M
