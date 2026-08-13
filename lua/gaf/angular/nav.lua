-- `gd` and the other jumps, resolved with treesitter (to classify what is under
-- the cursor) plus rg (to find the definition). No language server involved.
local context = require("gaf.angular.context")
local patterns = require("gaf.angular.patterns")
local search = require("gaf.angular.search")
local ts = require("gaf.angular.ts")

local notify, rg_run, rx = search.notify, search.rg_run, search.rx

local M = {}

-- ── cursor in a component -> its parents (callers) ─────────────────────────

local function class_range_of(node)
  local n = node
  while n do
    if n:type() == "class_declaration" then
      local srow, _, erow = n:range()
      return srow, erow
    end
    n = n:parent()
  end
end

local SELECTOR_QUERY = [[
  (decorator
    (call_expression
      function: (identifier) @fn (#eq? @fn "Component")
      arguments: (arguments
        (object
          (pair
            key: (property_identifier) @key (#eq? @key "selector")
            value: (string (string_fragment) @sel))))))
]]

local function extract_selectors(buf)
  local root = ts.buf_root(buf)
  if not root then return {} end
  local ok, query = pcall(vim.treesitter.query.parse, "typescript", SELECTOR_QUERY)
  if not ok then return {} end

  local out = {}
  for id, node in query:iter_captures(root, buf, 0, -1) do
    if query.captures[id] == "sel" then
      local raw = vim.treesitter.get_node_text(node, buf)
      local srow, erow = class_range_of(node)
      for piece in tostring(raw):gmatch("[^,]+") do -- 'app-foo, [appFoo]'
        local sel = piece:gsub("[%[%]%*%s]", "")
        if sel ~= "" then
          out[#out + 1] = { selector = sel, srow = srow, erow = erow }
        end
      end
    end
  end
  return out
end

function M.goto_parents()
  if vim.bo.filetype ~= "typescript" then
    notify("Not a TypeScript component buffer", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local fname = vim.api.nvim_buf_get_name(buf)
  local selectors = extract_selectors(buf)
  if #selectors == 0 then
    notify("No @Component selector found in this file", vim.log.levels.WARN)
    return
  end

  -- Component enclosing the cursor if the file defines several; else all.
  local wanted
  if #selectors == 1 then
    wanted = { selectors[1].selector }
  else
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    for _, s in ipairs(selectors) do
      if s.srow and s.erow and row >= s.srow and row <= s.erow then
        wanted = { s.selector }
        break
      end
    end
    wanted = wanted or vim.tbl_map(function(s) return s.selector end, selectors)
  end

  local pats = {}
  for _, sel in ipairs(wanted) do
    pats[#pats + 1] = patterns.tag_usage(sel)
  end
  search.rg_search("Parents of " .. table.concat(wanted, ", "), pats, search.search_root(fname), {
    skip = fname,
    dedupe = true,        -- one row per parent file
    filename_only = true, -- the path adds nothing when every row is a whole file
  })
end

-- ── attribute -> @Input/@Output or directive ───────────────────────────────

local function goto_attr(name, tag, root)
  local function directive_fallback()
    rg_run(patterns.directive(name), { root }, function(items)
      if #items > 0 then
        search.jump_item(items[1])
      else
        notify("No definition found for attribute '" .. name .. "'", vim.log.levels.WARN)
      end
    end)
  end

  if tag and tag:find("%-") then
    rg_run(patterns.selector(tag), { root }, function(defs)
      local file = defs[1] and defs[1].file
      if not file then
        directive_fallback()
        return
      end
      rg_run(patterns.member(name), { file }, function(members)
        if #members > 0 then
          search.jump_item(members[1])
        else
          directive_fallback() -- attr is a directive applied to a component element
        end
      end)
    end)
  else
    directive_fallback() -- native element: attr can only be a directive
  end
end

-- ── CSS class -> component stylesheet ──────────────────────────────────────
-- A class used in a component's template is styled by that same component's
-- stylesheet (Angular view encapsulation), so we resolve the CURRENT file's
-- styleUrls -- not the child component's.

-- Absolute, existing stylesheet paths from the component's styleUrls/styleUrl.
local function stylesheet_paths(buf)
  local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":h")
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local rels = {}
  local arr = text:match("styleUrls%s*:%s*%[(.-)%]")
  if arr then
    for p in arr:gmatch("['\"]([^'\"]+)['\"]") do rels[#rels + 1] = p end
  end
  local single = text:match("styleUrl%s*:%s*['\"]([^'\"]+)['\"]")
  if single then rels[#rels + 1] = single end
  local paths = {}
  for _, rel in ipairs(rels) do
    local abs = vim.fs.normalize(dir .. "/" .. rel)
    if vim.uv.fs_stat(abs) then paths[#paths + 1] = abs end
  end
  return paths
end

-- SCSS ampersand suffixes for a class produced by nested `&`-concatenation.
-- One candidate per delimiter run (`-`, `--`, `__`), so a class maps to any of
-- the `&`-nestings that could have built it:
--   `Data-name`      -> { "-name" }             (.Data { &-name {} })
--   `Tabs--olark`    -> { "--olark" }           (.Tabs { &--olark {} })
--   `Foo-bar-baz`    -> { "-bar-baz", "-baz" }  (one nest, or two)
-- Longest (closest-to-block) suffix first, so the most specific match wins.
local function bem_suffixes(cls)
  local out, seen = {}, {}
  for s in cls:gmatch("()[-_]+") do
    if s > 1 then -- a leading delimiter isn't a suffix of a parent block
      local suf = cls:sub(s)
      if not seen[suf] then
        seen[suf] = true
        out[#out + 1] = suf
      end
    end
  end
  table.sort(out, function(a, b) return #a > #b end)
  return out
end

-- Append `.cls { }` to the stylesheet, save, drop the cursor inside the braces.
local function create_class(file, cls)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_buf_set_lines(0, last, last, false, { "", "." .. cls .. " {", "  ", "}" })
  vim.cmd("write")
  pcall(vim.api.nvim_win_set_cursor, 0, { last + 3, 2 })
  vim.cmd("normal! zz")
end

local function goto_css(cls, buf)
  local paths = stylesheet_paths(buf)
  if #paths == 0 then
    notify("No stylesheet (styleUrls) found for this component", vim.log.levels.WARN)
    return
  end
  local function offer_create()
    local target = paths[1]
    vim.ui.select({ "Yes", "No" }, {
      prompt = "Class ." .. cls .. " not found. Create it in " .. vim.fn.fnamemodify(target, ":t") .. "?",
    }, function(choice)
      if choice == "Yes" then create_class(target, cls) end
    end)
  end
  -- 1) exact `.Class`  2) BEM `&--suffix`/`&__suffix`  3) offer to create.
  rg_run({ "\\." .. rx(cls) .. "\\b" }, paths, function(items)
    if #items > 0 then
      search.jump_item(items[1])
      return
    end
    local sufs = bem_suffixes(cls)
    if #sufs == 0 then return offer_create() end
    local pats = {}
    for _, s in ipairs(sufs) do pats[#pats + 1] = "&" .. rx(s) .. "\\b" end
    rg_run(pats, paths, function(items2)
      if #items2 > 0 then search.jump_item(items2[1]) else offer_create() end
    end, { no_type = true })
  end, { no_type = true })
end

-- ── template-local declarations ────────────────────────────────────────────
-- A name used in a template expression may be introduced by the template itself
-- rather than the component class -- an `@if (x$ | async; as foo)` alias, an
-- `@for (item of xs$)` loop variable, an `@let total = ...`, an `*ngIf="e as v"`
-- / `*ngFor="let i of ..."` binding, a `#ref`, or a `<ng-template let-ctx>` var.
-- `gd` on such a name lands on that binding site, so this runs before the
-- class-member search, which never finds these.

-- Record a declaration: identifier `id_node` is visible within `scope_node`.
-- opts.name/opts.col_off override the name/column (for `#ref`, `let-x` attrs).
local function push_local(out, buf, id_node, scope_node, opts)
  if not id_node or not scope_node then return end
  opts = opts or {}
  local dr, dc = id_node:range()
  local sr, sc, er, ec = scope_node:range()
  out[#out + 1] = {
    name = opts.name or vim.treesitter.get_node_text(id_node, buf),
    drow = dr + 1,
    dcol = dc + (opts.col_off or 0),
    srow = sr, scol = sc, erow = er, ecol = ec,
  }
end

-- Walk the injected angular tree, appending every declared local to `out`.
local function scan_locals(node, out, buf)
  local t = node:type()
  if t == "if_reference" then -- `@if (...; as x)` / `@else if (...; as x)`
    push_local(out, buf, ts.child_by_type(node, "identifier"), node:parent())
  elseif t == "for_declaration" then -- `@for (item of xs)`
    local id = (node:field("name") or {})[1] or ts.child_by_type(node, "identifier")
    push_local(out, buf, id, node:parent()) -- parent = for_statement (covers track expr + body)
  elseif t == "for_reference" then -- `@for (...; let i = $index)`
    local asgn = ts.child_by_type(node, "assignment_expression")
    if asgn then push_local(out, buf, ts.child_by_type(asgn, "identifier"), node:parent()) end
  elseif t == "let_statement" then -- `@let total = ...`
    local asgn = ts.child_by_type(node, "assignment_expression")
    if asgn then push_local(out, buf, ts.child_by_type(asgn, "identifier"), node:parent()) end
  elseif t == "structural_expression" then -- `*ngIf="e as v"`
    local armed, elem = false, ts.ancestor_of_type(node, "element")
    for c in node:iter_children() do
      if c:type() == "special_keyword" and vim.treesitter.get_node_text(c, buf) == "as" then
        armed = true
      elseif armed and c:type() == "identifier" then
        push_local(out, buf, c, elem)
        break
      end
    end
  elseif t == "structural_declaration" then -- `*ngFor="let item of xs; let i = index"`
    local elem = ts.ancestor_of_type(node, "element")
    for sa in node:iter_children() do
      if sa:type() == "structural_assignment" then
        local ids, let_kw = {}, false
        for c in sa:iter_children() do
          local ct = c:type()
          if ct == "special_keyword" and vim.treesitter.get_node_text(c, buf) == "let" then
            let_kw = true
          elseif ct == "identifier" then
            ids[#ids + 1] = c
          end
        end
        if let_kw and ids[1] then
          push_local(out, buf, ids[1], elem) -- `let i = index`
        elseif ids[2] then
          local sep = vim.treesitter.get_node_text(ids[2], buf)
          if sep == "of" or sep == "in" then
            push_local(out, buf, ids[1], elem) -- `let item of items`
          end
        end
      end
    end
  elseif t == "attribute_name" then
    local txt = vim.treesitter.get_node_text(node, buf)
    if txt:sub(1, 1) == "#" then -- `#ref` -- visible across the whole template
      push_local(out, buf, node, ts.root_of(node), { name = txt:sub(2), col_off = 1 })
    elseif txt:sub(1, 4) == "let-" then -- `<ng-template let-ctx>`
      push_local(out, buf, node, ts.ancestor_of_type(node, "element"), { name = txt:sub(5), col_off = 4 })
    end
  end
  for c in node:iter_children() do
    scan_locals(c, out, buf)
  end
end

local function scope_encloses(d, row, col)
  if row < d.srow or row > d.erow then return false end
  if row == d.srow and col < d.scol then return false end
  if row == d.erow and col >= d.ecol then return false end
  return true
end

-- If `name` binds to a template-local declaration in scope at the cursor, jump to
-- its binding site and return true; else return false so the class-member search
-- runs. The innermost enclosing declaration (latest-starting scope) wins.
local function goto_template_local(buf, name)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "typescript")
  if not ok or not parser then return false end
  parser:parse(true)
  local out = {}
  parser:for_each_tree(function(tree, ltree)
    if ltree:lang() == "angular" then scan_locals(tree:root(), out, buf) end
  end)

  local pos = vim.api.nvim_win_get_cursor(0)
  local crow, ccol = pos[1] - 1, pos[2]
  local best
  for _, d in ipairs(out) do
    if d.name == name and scope_encloses(d, crow, ccol) then
      if not best or d.srow > best.srow or (d.srow == best.srow and d.scol > best.scol) then
        best = d
      end
    end
  end
  if not best then return false end
  search.jump_to(vim.api.nvim_buf_get_name(buf), best.drow, best.dcol)
  return true
end

-- Jump to a value symbol's definition. PascalCase/CONST names -> a type, enum,
-- class or const anywhere under the search root (landing on `member` inside it
-- when the cursor was on `Enum.MEMBER`); lowerCamel names -> a class member
-- declared in the component file itself.
local function goto_symbol(name, member, buf, root)
  local function land(item)
    if not member then return search.jump_item(item) end
    rg_run({ "\\b" .. rx(member) .. "\\b" }, { item.file }, function(m)
      search.jump_item(m[1] or item)
    end)
  end

  if name:match("^%u") then
    rg_run(patterns.symbol_def(name), { root }, function(items)
      if #items == 0 then
        notify("No type/enum/class definition found for '" .. name .. "'", vim.log.levels.WARN)
      elseif #items == 1 or member then
        land(items[1])
      else
        search.show("Definition of " .. name, items, { dedupe = true })
      end
    end)
  else
    rg_run(patterns.member_decl(name), { vim.api.nvim_buf_get_name(buf) }, function(items)
      if #items > 0 then
        search.jump_item(items[1])
      else
        notify("No definition found for '" .. name .. "'", vim.log.levels.WARN)
      end
    end, { no_type = true })
  end
end

-- Returns true when the cursor was on an Angular template target (tag, attribute,
-- CSS class, or a symbol in a binding expression) and this function claimed the
-- jump -- even if the target could not be resolved. Returns false only when the
-- cursor is on plain TypeScript, so the caller can fall back to LSP `gd`.
function M.goto_definition()
  if vim.bo.filetype ~= "typescript" then return false end
  local buf = vim.api.nvim_get_current_buf()
  local root = search.buf_root(buf)

  -- A symbol in a binding value/interpolation (`ButtonSize.SMALL`, `plainVar`)
  -- resolves to its TS definition, before tag/attribute classification. A name
  -- the template itself binds (`@if ... as x`, `@for` var, `@let`, `#ref`) wins
  -- over the class-member search -- that's the name's lexical declaration.
  local sym = context.symbol_under_cursor(buf)
  if sym then
    if not goto_template_local(buf, sym.name) then
      goto_symbol(sym.name, sym.member, buf, root)
    end
    return true
  end

  local tgt = context.target_under_cursor(buf)
  if not tgt then return false end -- plain TS: let the caller use LSP definition

  if tgt.kind == "tag" then
    if not tgt.name or not tgt.name:find("%-") then
      notify("'" .. (tgt.name or "?") .. "' is a native element, not a component", vim.log.levels.WARN)
      return true
    end
    -- Selector definition: one file -> jump straight; multiple files defining the
    -- same selector (e.g. projects + contests both define `app-collaborator-info`)
    -- -> picker, so a duplicated name is still reachable.
    search.rg_search("Definition of " .. tgt.name, patterns.selector(tgt.name), root, { dedupe = true })
    return true
  end

  -- A class binding -> jump to the CSS; anything else -> @Input/@Output/directive.
  local name = tgt.name
  local cls
  if name:match("^class%.") then
    cls = name:sub(7) -- after "class."
  elseif name == "class" or name == "ngClass" then
    cls = context.class_token_under_cursor()
    if not cls or cls == "class" or cls == "ngClass" then
      notify("Place the cursor on a class name", vim.log.levels.WARN)
      return true
    end
  end
  if cls then
    goto_css(cls, buf)
  else
    goto_attr(name, tgt.tag, root)
  end
  return true
end

-- ── prompt for a component name -> its definition ──────────────────────────
-- Type a class name (`FooComponent`, prefix ok) or a selector (`app-foo`); jump
-- to the single hit, or pick when several match. Seeds the prompt with the word
-- under the cursor.
function M.goto_component_prompt()
  local root = search.buf_root(0)
  vim.ui.input({ prompt = "Component (class or selector): ", default = vim.fn.expand("<cword>") }, function(input)
    if not input then return end
    input = vim.trim(input)
    if input == "" then return end
    search.rg_search("Component " .. input, patterns.component(input), root, { dedupe = true })
  end)
end

return M
