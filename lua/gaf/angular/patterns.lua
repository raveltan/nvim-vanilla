-- rg patterns for the declarations the lookups chase. Kept together so the
-- regex dialect (rg, not Lua) lives in one file.
local rx = require("gaf.angular.search").rx

local M = {}

-- Exact selector definition: the tag is a whole token, never `x-app-foo` or
-- `app-foo-bar`. Sole value, or a delimited member of a comma list.
function M.selector(sel)
  sel = rx(sel)
  return {
    "selector:\\s*['\"]\\s*" .. sel .. "\\s*['\"]",
    "selector:\\s*['\"][^'\"]*[\\s,\\[]" .. sel .. "[\\s,\\]'\"]",
  }
end

-- Declarations of an @Input/@Output/signal/host-binding named `name`.
function M.member(name)
  name = rx(name)
  return {
    "@Input\\([^)]*\\)\\s*(set\\s+|get\\s+)?" .. name .. "\\b", -- @Input(...) name / set name(
    "@Input\\(\\s*['\"]" .. name .. "['\"]",                    -- @Input('name') alias
    "@Output\\([^)]*\\)\\s*" .. name .. "\\b",
    "@Output\\(\\s*['\"]" .. name .. "['\"]",
    "@HostBinding\\(\\s*['\"][^'\"]*" .. name .. "\\b",
    "\\b" .. name .. "\\s*=\\s*(input|output|model)\\b", -- signal input()/output()/model()
  }
end

-- Attribute-selector directive: selector: '[name]'.
function M.directive(name)
  return { "selector:\\s*['\"][^'\"]*\\[" .. rx(name) .. "\\]" }
end

-- Definition of a type-like symbol referenced inside a template expression
-- (`[size]="ButtonSize.SMALL"` -> the `ButtonSize` enum/class/type/const).
function M.symbol_def(name)
  name = rx(name)
  return {
    "(export\\s+)?(declare\\s+)?(const\\s+)?enum\\s+" .. name .. "\\b",
    "(export\\s+)?(abstract\\s+)?class\\s+" .. name .. "\\b",
    "(export\\s+)?interface\\s+" .. name .. "\\b",
    "(export\\s+)?type\\s+" .. name .. "\\b",
    "(export\\s+)?(declare\\s+)?const\\s+" .. name .. "\\b",
    "(export\\s+)?function\\s+" .. name .. "\\b",
  }
end

-- Declaration of a component-class member (`plainVar`, `onClick`) referenced in
-- a template expression -- anchored at line start so a template usage of the
-- same name (in the decorator above) is not mistaken for the declaration.
function M.member_decl(name)
  name = rx(name)
  local mods = "(readonly\\s+|private\\s+|public\\s+|protected\\s+|static\\s+|override\\s+|abstract\\s+|get\\s+|set\\s+|async\\s+)*"
  -- Optional inline decorator before the member, e.g. `@Input({ required: true })
  -- foo$: Observable<...>` -- the name isn't at line start then. (`[^)]*` covers
  -- the common option-object/alias args; a decorator on its own line is matched by
  -- the plain form since the member line then starts with the name.)
  local decorator = "(@\\w+\\([^)]*\\)\\s*)?"
  return {
    "^\\s*" .. decorator .. mods .. name .. "\\s*[?!]?\\s*[:=(]",
    "^\\s*(public\\s+|private\\s+|protected\\s+|readonly\\s+)+" .. name .. "\\b",
  }
end

-- Locate a component by free-text name: matches a class declaration whose name
-- starts with `name` (so `Foo` finds `FooComponent`) and, when `name` looks like
-- a selector, its `selector:` definition too.
function M.component(name)
  local pats = { "class\\s+" .. rx(name) }
  vim.list_extend(pats, M.selector(name))
  return pats
end

-- Exported enum / type alias, for value completion.
function M.exported_type(name)
  name = rx(name)
  return {
    "export\\s+(declare\\s+)?(const\\s+)?enum\\s+" .. name .. "\\b",
    "export\\s+type\\s+" .. name .. "\\b",
  }
end

-- Element opening tag only: `<app-foo` then a word boundary. Catches
-- `<app-foo>`, `<app-foo/>` and multiline openers; skips closing tags and bare
-- references, so each usage counts once. \b stops app-foo matching app-foobar.
function M.tag_usage(sel)
  return "<" .. rx(sel) .. "\\b"
end

return M
