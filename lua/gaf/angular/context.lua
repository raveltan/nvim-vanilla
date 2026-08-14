-- What the cursor is sitting on inside an inline Angular template.
--
-- Two families of read live here. `gd` uses the injected `angular` tree, which
-- is precise but needs a well-formed template. Completion cannot: while an
-- attribute is being typed the start tag is unclosed, and treesitter's error
-- recovery misattributes the cursor to the nearest well-formed *enclosing*
-- element (a cursor in `<app-foo [` resolves to the surrounding `<div>`). So the
-- completion reads are a backward text scan over the tag segment -- the text
-- from the last unclosed `<` to the cursor -- which is exactly the state
-- completion fires in.
--
-- That segment is computed once per (buffer, changedtick, cursor) and shared:
-- one completion round asks for the tag name, the quote state and the attribute
-- being valued, and rebuilding a 30-line window for each was the bulk of the
-- work done per keystroke. The template check is memoised on the same key, for
-- the same reason: three of the four modes ask it.
local ts = require("gaf.angular.ts")

local M = {}

-- Lines of a multiline start tag we look back over.
local WINDOW = 30

local cache = { key = nil }

local function state(buf)
  local pos = vim.api.nvim_win_get_cursor(0)
  local key = table.concat({ buf, vim.api.nvim_buf_get_changedtick(buf), pos[1], pos[2] }, ":")
  if cache.key ~= key then cache = { key = key, row = pos[1], col = pos[2] } end
  return cache
end

-- Text from the last `<` with no `<`/`>` after it up to the cursor, or nil when
-- the cursor isn't inside an open start tag. Scans a WINDOW-line window so
-- multiline start tags resolve.
function M.tag_segment(buf)
  local c = state(buf)
  if c.seg_done then return c.seg end
  c.seg_done = true

  local lines = vim.api.nvim_buf_get_lines(buf, math.max(0, c.row - WINDOW), c.row, false)
  if #lines > 0 then
    lines[#lines] = lines[#lines]:sub(1, c.col) -- up to the cursor only
    local text = table.concat(lines, "\n")
    local lt = text:find("<[^<>]*$")
    c.seg = lt and text:sub(lt) or nil
  end
  return c.seg
end

-- The component tag whose *open* start tag encloses the cursor (`<app-foo …▏`),
-- or nil. Callers gate on a `-` in the name (component selectors always have
-- one), discarding the false hits this can produce -- a `<` in a binding
-- expression, or a TS generic like `Array<`.
function M.enclosing_tag_name(buf)
  local seg = M.tag_segment(buf)
  return seg and seg:match("^<([%w%-]+)")
end

-- True when the cursor sits inside a quoted attribute value of the current open
-- start tag (typing a binding *value*, not an attribute *name*).
function M.in_attr_value(buf)
  local c = state(buf)
  if c.quoted == nil then
    local seg = M.tag_segment(buf) or ""
    local q
    for i = 1, #seg do
      local ch = seg:byte(i)
      if q then
        if ch == q then q = nil end
      elseif ch == 34 or ch == 39 then -- " '
        q = ch
      end
    end
    c.quoted = q ~= nil
  end
  return c.quoted
end

-- The attribute whose value the cursor is inside: its input name (brackets
-- stripped) and whether it's a property binding (`[x]="…"`) vs static (`x="…"`).
function M.value_attr(buf)
  local seg = M.tag_segment(buf)
  if not seg then return nil end
  local br, attr = seg:match("(%[?)([%w%-]+)%]?%s*=%s*['\"][^'\"]*$")
  if not attr then return nil end
  return attr, br == "["
end

-- Tag-name position: a `<` followed only by tag-name characters. Returns the
-- 0-indexed column of the `<` and the partial name typed after it, so a source
-- can replace the partial tag rather than append to it. Whitespace, a `>` or an
-- attribute in between means the name is already written and attribute
-- completion owns the cursor.
function M.tag_prefix()
  local before = vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])
  local lt = before:find("<[%w%-]*$")
  if not lt then return nil end
  return lt - 1, before:sub(lt + 1)
end

-- `Enum.` / `Enum.partial` typed immediately before the cursor.
function M.enum_prefix()
  local before = vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])
  return before:match("([%u][%w_]*)%.[%w_]*$")
end

-- True when the cursor is inside a `template_string` (a `@Component` inline
-- template). Uses the plain TS tree -- present regardless of the angular
-- injection -- so it's reliable even before the injected parser has run.
function M.in_template(buf)
  local c = state(buf)
  if c.template ~= nil then return c.template end
  c.template = false
  local node = ts.node_at_cursor(buf)
  while node do
    if node:type() == "template_string" then
      c.template = true
      break
    end
    node = node:parent()
  end
  return c.template
end

-- CSS identifier under the cursor (allows - and _).
function M.class_token_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1 -- 1-indexed at the cursor
  local b, e = col, col
  while b > 1 and line:sub(b - 1, b - 1):match("[%w_%-]") do b = b - 1 end
  while e <= #line and line:sub(e, e):match("[%w_%-]") do e = e + 1 end
  local tok = line:sub(b, e - 1)
  return tok ~= "" and tok or nil
end

-- ── the injected angular tree (`gd`) ───────────────────────────────────────

local TAG_NODES = { element = true, start_tag = true, self_closing_tag = true, end_tag = true }
local ATTR_NODES = {
  attribute = true, property_binding = true, event_binding = true,
  two_way_binding = true, structural_directive = true, bound_attribute = true,
}

-- Identifiers that live in a template *expression* (RHS of a binding, an event
-- handler, a structural `*ngIf`, or an `{{ interpolation }}`) rather than being
-- a tag or attribute name. These resolve to a TS definition, not the DOM.
local VALUE_CTX = { expression = true, interpolation = true, structural_expression = true }
-- Direct parent of an identifier that IS an attribute/binding NAME (not a value).
local NAME_PARENT = { binding_name = true, structural_directive = true }

-- Named node under the cursor in the injected (angular/html) tree.
local function injected_node(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "typescript")
  if not ok or not parser then return nil end
  parser:parse(true) -- include injections (template strings)
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  local lt = parser:language_for_range({ row, col, row, col })
  local tree = lt:tree_for_range({ row, col, row, col }, { ignore_injections = false })
  if not tree then return nil end
  return tree:root():named_descendant_for_range(row, col, row, col)
end

-- First tag_name in the subtree, depth-first (start_tag precedes nested content).
local function first_tag_name(node, buf)
  if node:type() == "tag_name" then
    return vim.treesitter.get_node_text(node, buf)
  end
  for child in node:iter_children() do
    local found = first_tag_name(child, buf)
    if found then return found end
  end
end

-- Classify what's under the cursor in a template:
--   { kind = "tag",  name = "app-foo" }
--   { kind = "attr", name = "someInput", tag = "app-foo" }  (tag may be nil)
function M.target_under_cursor(buf)
  local node = injected_node(buf)
  while node do
    local t = node:type()
    if t == "tag_name" then
      return { kind = "tag", name = vim.treesitter.get_node_text(node, buf) }
    elseif ATTR_NODES[t] then
      -- e.g. `[foo]="bar"`, `(click)="x()"`, `*ngFor="..."`, `class="x"`, `flDir`.
      local raw = vim.treesitter.get_node_text(node, buf)
      local name = (raw:match("^[^=]*") or ""):gsub("[%s%[%]%(%)%*%#\"'@]", "")
      if name == "" then return nil end
      local tag
      local p = node
      while p do
        if TAG_NODES[p:type()] then
          tag = first_tag_name(p, buf)
          break
        end
        p = p:parent()
      end
      return { kind = "attr", name = name, tag = tag }
    elseif TAG_NODES[t] then
      return { kind = "tag", name = first_tag_name(node, buf) }
    end
    node = node:parent()
  end
end

-- If the cursor sits on an identifier inside a template expression, resolve the
-- symbol to look up: `{ name, member }`. For `ButtonSize.SMALL`, both the object
-- (`ButtonSize`) and the property (`SMALL`) yield name="ButtonSize", member="SMALL".
-- Returns nil when the cursor is on a tag/attribute name or plain markup.
function M.symbol_under_cursor(buf)
  local node = injected_node(buf)
  if not node then return nil end
  local t = node:type()
  if t ~= "identifier" and t ~= "property_identifier" then return nil end
  local parent = node:parent()
  if parent and NAME_PARENT[parent:type()] then return nil end -- attr/binding name

  -- Must sit inside a value expression, not e.g. a plain quoted attribute.
  local in_value, anc = false, node
  while anc do
    if VALUE_CTX[anc:type()] then in_value = true break end
    if TAG_NODES[anc:type()] then break end
    anc = anc:parent()
  end
  if not in_value then return nil end

  local name = vim.treesitter.get_node_text(node, buf)
  local member
  if parent and parent:type() == "member_expression" then
    local obj = parent:field("object")[1]
    local prop = parent:field("property")[1]
    if prop and prop:id() == node:id() and obj then
      -- cursor on `.SMALL` -> the type is the object's rightmost identifier.
      local objtext = vim.treesitter.get_node_text(obj, buf)
      name = objtext:match("[%w_%$]+$") or objtext
      member = vim.treesitter.get_node_text(node, buf)
    elseif obj and obj:id() == node:id() and prop then
      -- cursor on `ButtonSize` -> keep it, remember the member to land on.
      member = vim.treesitter.get_node_text(prop, buf)
    end
  end
  return { name = name, member = member }
end

return M
