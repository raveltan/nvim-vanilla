-- treesitter helpers shared by the navigation, parsing and edit builders.
-- Nothing here knows about Angular beyond the shapes the TS grammar gives a
-- decorator; the Angular-specific reads live in their own modules.
local M = {}

function M.read_file(file)
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok then return nil end
  return table.concat(lines, "\n")
end

-- Parsed root of a buffer's TypeScript tree, or nil.
function M.buf_root(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "typescript")
  if not ok or not parser then return nil end
  local tree = (parser:parse() or {})[1]
  return tree and tree:root() or nil
end

-- Parsed root of a source string, or nil. Used for files read off disk, where a
-- buffer would be wasteful.
function M.str_root(src)
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, "typescript")
  if not ok or not parser then return nil end
  local tree = (parser:parse() or {})[1]
  return tree and tree:root() or nil
end

-- Read + parse a file in one step -> root, src (or nil).
function M.parse_file(file)
  local src = M.read_file(file)
  if not src then return nil end
  local root = M.str_root(src)
  if not root then return nil end
  return root, src
end

-- Innermost named node at the cursor in `bufnr`'s own (non-injected) tree.
function M.node_at_cursor(bufnr)
  local root = M.buf_root(bufnr)
  if not root then return nil end
  local pos = vim.api.nvim_win_get_cursor(0)
  return root:named_descendant_for_range(pos[1] - 1, pos[2], pos[1] - 1, pos[2])
end

-- ── traversal ──────────────────────────────────────────────────────────────

function M.ancestor_of_type(node, t)
  local n = node
  while n do
    if n:type() == t then return n end
    n = n:parent()
  end
end

function M.child_by_type(node, t)
  for c in node:iter_children() do
    if c:type() == t then return c end
  end
end

function M.each_node(node, t, cb)
  if node:type() == t then cb(node) end
  for c in node:iter_children() do M.each_node(c, t, cb) end
end

-- Topmost ancestor -- the `document` of an injected template tree.
function M.root_of(node)
  local n = node
  while n:parent() do n = n:parent() end
  return n
end

-- ── decorators ─────────────────────────────────────────────────────────────

-- Decorator's called name + its call node: `@Input('x')` -> "Input", <call>.
function M.decorator_call(dec, src)
  for c in dec:iter_children() do
    local t = c:type()
    if t == "call_expression" then
      local fn = c:field("function")[1]
      return fn and vim.treesitter.get_node_text(fn, src), c
    elseif t == "identifier" then -- `@Input` with no parens
      return vim.treesitter.get_node_text(c, src), nil
    end
  end
end

-- The class a decorator applies to: its own parent for a plain class, or its
-- sibling under the `export_statement` when the class is exported (which is how
-- the TS grammar attaches `@Component` to an `export class`).
function M.decorated_class(dec)
  local p = dec:parent()
  if not p then return nil end
  if p:type() == "class_declaration" then return p end
  return M.child_by_type(p, "class_declaration")
end

-- The options object of a decorator's call, or nil.
function M.decorator_object(call)
  local args = call and call:field("arguments")[1]
  local obj = args and args:named_child(0)
  return (obj and obj:type() == "object") and obj or nil
end

-- The `key: value` pair node in a decorator's options object, or nil. Quotes are
-- stripped from the key so `'selector'` matches `selector`.
function M.decorator_pair(obj, key, src)
  for pair in obj:iter_children() do
    if pair:type() == "pair" then
      local k = pair:field("key")[1]
      if k and (vim.treesitter.get_node_text(k, src):gsub("['\"]", "")) == key then
        return pair
      end
    end
  end
end

-- Source text of `key`'s value in a decorator's options object, or nil.
function M.decorator_option(obj, key, src)
  local pair = M.decorator_pair(obj, key, src)
  local v = pair and pair:field("value")[1]
  return v and vim.treesitter.get_node_text(v, src)
end

-- First argument of a call if it's a string literal (the @Input/@Output alias).
function M.first_string_arg(call, src)
  if not call then return nil end
  local args = call:field("arguments")[1]
  local a = args and args:named_child(0)
  if a and a:type() == "string" then
    return (vim.treesitter.get_node_text(a, src):gsub("['\"]", ""))
  end
end

-- ── types + edits ──────────────────────────────────────────────────────────

function M.strip_annotation(s)
  return (s:gsub("^%s*:%s*", ""))
end

-- First balanced `<...>` generic argument in a call/new-expression's text
-- (`EventEmitter<Map<a,b>>` -> `Map<a,b>`, `input<ButtonSize>()` -> `ButtonSize`).
function M.angle_generic(text)
  local i = text:find("<")
  if not i then return nil end
  local depth = 0
  for k = i, #text do
    local ch = text:sub(k, k)
    if ch == "<" then
      depth = depth + 1
    elseif ch == ">" then
      depth = depth - 1
      if depth == 0 then
        local inner = vim.trim(text:sub(i + 1, k - 1))
        return inner ~= "" and inner or nil
      end
    end
  end
end

-- LSP-shaped range for a node, so a caller can reason about a position without
-- holding a treesitter node (which dies on the next parse).
function M.node_range(node)
  local sr, sc, er, ec = node:range()
  return { start = { line = sr, character = sc }, ["end"] = { line = er, character = ec } }
end

function M.insert_at(row, col, text)
  return {
    range = { start = { line = row, character = col }, ["end"] = { line = row, character = col } },
    newText = text,
  }
end

return M
