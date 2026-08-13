-- tagmatch.nvim
-- Treesitter-based tag matching: jump between open/close tags with `%`, and
-- inner/around tag text objects `i%` / `a%`. Works across every grammar exposing
-- HTML- or JSX-style element nodes, native or injected, so html, xml, Angular
-- (including inline `template:` strings in .ts), JSX/TSX, Vue, Svelte and php are
-- all covered.
--
-- Treesitter rather than matchit's `b:match_words` because matchit matches inside
-- string literals poorly (Angular inline templates), cannot follow injected
-- trees, and its html mode matches the angle brackets `<`..`>` rather than the
-- open/close tag pair. The tree knows the real structure, including hyphenated
-- custom elements (`<fl-button>`), nesting, and multi-line tags.
--
-- Outside a tag, or in a buffer with no tag tree at the cursor, `%` falls through
-- to the builtin and the text objects do nothing, so normal bracket matching is
-- untouched.

local M = {}

-- Node types, unioned across the two families. They are globally unique, so a
-- single set per role disambiguates html-family from jsx-family without
-- dispatching on language.
local OPEN = { start_tag = true, jsx_opening_element = true }
local CLOSE = { end_tag = true, jsx_closing_element = true }
local SELF = { self_closing_tag = true, jsx_self_closing_element = true }
local ELEMENT = { element = true, jsx_element = true }
-- Tag-name node types: tag_name in the html family, identifier plus the dotted
-- and namespaced component forms in the jsx family.
local NAME = {
  tag_name = true, identifier = true, member_expression = true,
  nested_identifier = true, jsx_namespace_name = true,
}

local function is_tagish(t)
  return ELEMENT[t] or OPEN[t] or CLOSE[t] or SELF[t]
end

local config = {
  -- The treesitter check self-gates, so a broad list is safe. In a buffer with no
  -- tag node at the cursor the mappings fall back.
  filetypes = {
    "html", "xml", "xhtml", "htmlangular", "vue", "svelte", "handlebars",
    "htmldjango", "heex", "php", "markdown", "javascript",
    "javascriptreact", "typescript", "typescriptreact", "astro",
  },
  -- Set any to false to skip that mapping.
  mappings = { jump = "%", inner = "i%", around = "a%" },
}

local function cursor_rc()
  local p = vim.api.nvim_win_get_cursor(0) -- {row (1-based), col (0-based)}
  return p[1] - 1, p[2]
end

-- Searched across all injected trees, so the html inside php or the angular
-- inside a `.ts` template string is found even though the outer tree reports only
-- text there.
local function tag_node_at(row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, 0)
  if not ok or not parser then return nil end
  pcall(parser.parse, parser, true)
  local found
  parser:for_each_tree(function(tree, _ltree)
    local root = tree and tree:root()
    if not (root and vim.treesitter.is_in_node_range(root, row, col)) then return end
    local node = root:named_descendant_for_range(row, col, row, col)
    local probe = node
    while probe do
      if is_tagish(probe:type()) then
        found = node -- innermost tree wins (later iterations are deeper)
        return
      end
      probe = probe:parent()
    end
  end)
  return found
end

local function ancestor(node, pred)
  while node do
    if pred(node:type()) then return node end
    node = node:parent()
  end
end

local function child_tags(element)
  local open, close
  for child in element:iter_children() do
    local t = child:type()
    if OPEN[t] then
      open = child
    elseif CLOSE[t] then
      close = child
    end
  end
  return open, close
end

local function name_of(tag)
  for child in tag:iter_children() do
    if NAME[child:type()] then return child end
  end
end

-- Name nodes to edit for a rename, {open, close} or {name} for self-closing, but
-- only when the cursor sits on tag markup, meaning the name itself or the tag's
-- punctuation (`<`, `>`, `/`). Anywhere else (attributes, content) returns nil so
-- the caller can fall through to LSP rename.
local function rename_targets()
  local row, col = cursor_rc()
  local node = tag_node_at(row, col)
  if not node then return nil end
  local tag = ancestor(node, function(t) return OPEN[t] or CLOSE[t] or SELF[t] end)
  if not tag then return nil end
  if not (OPEN[node:type()] or CLOSE[node:type()] or SELF[node:type()]) then
    local name = name_of(tag)
    if not (name and vim.treesitter.is_in_node_range(name, row, col)) then return nil end
  end

  local names = {}
  if SELF[tag:type()] then
    names[1] = name_of(tag)
  else
    local element = ancestor(tag:parent(), function(t) return ELEMENT[t] end)
    if not element then return nil end
    local open, close = child_tags(element)
    local on, cn = open and name_of(open), close and name_of(close)
    if on then names[#names + 1] = on end
    if cn then names[#names + 1] = cn end
  end
  if #names == 0 then return nil end
  return names
end

-- Treesitter's exclusive end (row, col) to an inclusive one, wrapping a col-0 end
-- to the previous line's last column.
local function excl_to_incl(row, col)
  if col > 0 then return row, col - 1 end
  local prev = row - 1
  local line = vim.api.nvim_buf_get_lines(0, prev, prev + 1, false)[1] or ""
  return prev, math.max(#line - 1, 0)
end

-- Rows and cols are 0-based with `ec` inclusive. Must not already be in visual
-- mode when `` `<v`> `` runs, where `v` would toggle visual off, and
-- operator-pending needs that `v` to start the visual it consumes.
local function select_charwise(sr, sc, er, ec)
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd("normal! \27")
  end
  vim.api.nvim_buf_set_mark(0, "<", sr + 1, sc, {})
  vim.api.nvim_buf_set_mark(0, ">", er + 1, ec, {})
  vim.cmd("normal! `<v`>")
end

function M.has_tag()
  local node = tag_node_at(cursor_rc())
  return node ~= nil and ancestor(node, function(t) return ELEMENT[t] or SELF[t] end) ~= nil
end

function M.jump()
  local node = tag_node_at(cursor_rc())
  local tag = node and ancestor(node, function(t) return OPEN[t] or CLOSE[t] or SELF[t] end)
  if not tag then
    pcall(vim.cmd, "normal! %") -- builtin, avoids recursing into this mapping
    return
  end
  if SELF[tag:type()] then return end -- nothing to pair with

  local element = ancestor(tag:parent(), function(t) return ELEMENT[t] end)
  if not element then return end
  local open, close = child_tags(element)
  if not (open and close) then return end

  local target = OPEN[tag:type()] and close or open
  local trow, tcol = target:start()
  vim.api.nvim_win_set_cursor(0, { trow + 1, tcol })
end

-- Invoked via our <Plug>, so an element is already known to enclose the cursor.
function M.select(inner)
  local node = tag_node_at(cursor_rc())
  local element = node and ancestor(node, function(t) return ELEMENT[t] or SELF[t] end)
  if not element then return end

  if not inner or SELF[element:type()] then
    if inner then return end -- nothing inside a self-closing tag
    local sr, sc, er, ec = element:range()
    er, ec = excl_to_incl(er, ec)
    return select_charwise(sr, sc, er, ec)
  end

  -- The span of named content children avoids leaking a multi-line start tag's
  -- trailing `>`. Fall back to the byte span between the tags when the content is
  -- non-native, e.g. blade `{{ }}` leaves no html child node.
  local first, last
  for child in element:iter_children() do
    local t = child:type()
    if child:named() and not (OPEN[t] or CLOSE[t] or SELF[t]) then
      first = first or child
      last = child
    end
  end

  local sr, sc, er, ec
  if first then
    sr, sc = first:start()
    er, ec = excl_to_incl(last:end_())
  else
    local open, close = child_tags(element)
    if not (open and close) then return end
    sr, sc = open:end_()
    er, ec = excl_to_incl(close:start())
    local line = vim.api.nvim_buf_get_lines(0, sr, sr + 1, false)[1] or ""
    if sc > #line then -- start tag's `>` ended its line: content begins next line
      sr, sc = sr + 1, 0
    end
  end
  if sr > er or (sr == er and sc > ec) then return end -- empty element
  select_charwise(sr, sc, er, ec)
end

-- Lets callers decide routing, e.g. defer uppercase JSX components to LSP rename,
-- without triggering the prompt.
function M.rename_info()
  local targets = rename_targets()
  if not targets then return nil end
  return vim.treesitter.get_node_text(targets[1], 0)
end

-- Renames the opening and closing tag together, or the single name of a
-- self-closing tag. Returns false when the cursor is not on tag markup and true
-- once the prompt is issued, which does not mean the rename happened.
function M.rename()
  local targets = rename_targets()
  if not targets then return false end
  local old = vim.treesitter.get_node_text(targets[1], 0)

  vim.ui.input({ prompt = "Rename tag: ", default = old }, function(new)
    if not new or new == "" or new == old then return end
    -- Bottom-up so earlier ranges stay valid after each edit.
    table.sort(targets, function(a, b)
      local ar, ac = a:start()
      local br, bc = b:start()
      return ar > br or (ar == br and ac > bc)
    end)
    for _, n in ipairs(targets) do
      local sr, sc, er, ec = n:range()
      vim.api.nvim_buf_set_text(0, sr, sc, er, ec, { new })
    end
    vim.notify(("Renamed <%s> → <%s> (%d tag%s)"):format(
      old, new, #targets, #targets == 1 and "" or "s"))
  end)
  return true
end

local function attach(buf)
  local m, o = config.mappings, { buffer = buf, silent = true }
  if m.jump then
    vim.keymap.set({ "n", "x" }, m.jump, M.jump,
      vim.tbl_extend("force", o, { desc = "tagmatch: jump matching tag" }))
  end
  -- Visual and operator-pending go through <expr> and RETURN the keys. An
  -- operator cannot take an imperative selection because it aborts before async
  -- keys run, so returning the <Plug> routes to the imperative handler. Off a
  -- tag, `""` makes the key a no-op rather than an error.
  if m.inner then
    vim.keymap.set({ "x", "o" }, m.inner, function()
      return M.has_tag() and "<Plug>(TagMatchInner)" or ""
    end, vim.tbl_extend("force", o, { expr = true, remap = true, desc = "tagmatch: inner tag" }))
  end
  if m.around then
    vim.keymap.set({ "x", "o" }, m.around, function()
      return M.has_tag() and "<Plug>(TagMatchAround)" or ""
    end, vim.tbl_extend("force", o, { expr = true, remap = true, desc = "tagmatch: around tag" }))
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  -- Where the <expr> maps route for the actual selection. Global but inert unless
  -- invoked.
  vim.keymap.set({ "x", "o" }, "<Plug>(TagMatchInner)", function() M.select(true) end, { silent = true })
  vim.keymap.set({ "x", "o" }, "<Plug>(TagMatchAround)", function() M.select(false) end, { silent = true })

  local want = {}
  for _, ft in ipairs(config.filetypes) do
    want[ft] = true
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("tagmatch", { clear = true }),
    pattern = config.filetypes,
    callback = function(args) attach(args.buf) end,
  })

  -- Buffers already open when setup runs, e.g. lazy-loaded after the file.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and want[vim.bo[buf].filetype] then
      attach(buf)
    end
  end
end

return M
