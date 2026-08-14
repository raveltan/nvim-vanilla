-- blink.cmp source: completion inside Angular inline templates. Offers the
-- component tags in scope (`<fl-bu` -> the whole `<fl-button>…</fl-button>`
-- element), a component's @Input/@Output names once the cursor is inside a
-- `<app-foo …>` start tag, and the values those inputs accept. Resolution and
-- caching live in gaf.angular.completion / .edits; this file only shapes the
-- results into blink items. Wired in lua/core/completion.lua as provider
-- `angular`, prepended to the typescript source list.
--
-- Accepting a tag also makes it resolve. A standalone consumer takes an import
-- statement and an `imports: [ ]` entry in its own file, attached by resolve as
-- additionalTextEdits; an NgModule-declared one needs the entry in the module
-- DECLARING it -- another file, which additionalTextEdits cannot reach (LSP
-- defines them as same-buffer) and only M:execute can. `vim.g.angular_auto_wire`
-- is read at accept time, so it can be flipped mid-session:
--   "all" (default) -- edit the owning @NgModule too, saving it if it was clean
--   "standalone"    -- this buffer's edits only, no second file
--   false           -- same as "standalone"
-- Anything unrecognised reads as "all", which covers 3837 of the webapp's 5209
-- components.
local completion = require("gaf.angular.completion")
local component = require("gaf.angular.component")
local context = require("gaf.angular.context")
local edits = require("gaf.angular.edits")
local search = require("gaf.angular.search")

local kinds = vim.lsp.protocol.CompletionItemKind
local Snippet = vim.lsp.protocol.InsertTextFormat.Snippet

local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

function M:enabled()
  return vim.bo.filetype == "typescript"
end

-- `[` / `(` are the Angular binding brackets, `<` opens a tag, `.` an enum
-- member. `<` also starts a TS generic, which is harmless -- the data layer only
-- answers inside an inline template. Letters come free from blink's
-- show_on_keyword; space is deliberately omitted, since it would pop the menu
-- after every space in a TS file.
function M:get_trigger_characters()
  return { "[", "(", ".", "<" }
end

-- The binding to insert, brackets included, with `inner` as the value (a snippet
-- tab-stop by default). Outputs use (), two-way models use [()], else [].
local function binding(kind, name, inner)
  if kind == "output" then
    return "(" .. name .. ')="' .. inner .. '"'
  elseif kind == "model" then
    return "[(" .. name .. ')]="' .. inner .. '"'
  end
  return "[" .. name .. ']="' .. inner .. '"'
end

-- Readable one-line signature for the docs popup.
local function signature(it)
  local ty = it.type and (": " .. it.type) or ""
  local alias = it.name ~= it.prop and ("  (as [" .. it.name .. "])") or ""
  if it.kind == "output" then
    return "@Output() " .. it.prop .. (it.type and (": EventEmitter<" .. it.type .. ">") or "") .. alias
  elseif it.kind == "model" then
    return it.prop .. " = model<" .. (it.type or "?") .. ">()" .. alias
  end
  return "@Input() " .. it.prop .. ty .. alias
end

-- Docs popup body: the signature, then the member's own doc comment, then where
-- it comes from. `extra` (enum info) is appended by resolve.
local function doc_value(it, meta, extra)
  local parts = { "```typescript", signature(it), "```" }
  if it.doc and it.doc ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = it.doc
  end
  parts[#parts + 1] = ""
  parts[#parts + 1] = "`" .. meta.tag .. "` — " .. vim.fn.fnamemodify(meta.file, ":t")
  if extra then parts[#parts + 1] = extra end
  return table.concat(parts, "\n")
end

local function kind_icon(it)
  if it.kind == "output" then return kinds.Event end
  if it.kind == "model" then return kinds.Reference end
  return kinds.Property
end

-- A tag item inserts the whole element. The webapp writes paired tags almost
-- exclusively (28506 `</fl-x>` closings against 134 self-closing), so the
-- self-closing form is never worth offering. $1 sits in the start tag for
-- bindings, $0 in the body where the content goes.
local function tag_snippet(sel)
  return "<" .. sel .. "$1>$0</" .. sel .. ">"
end

-- Is the cross-file NgModule wiring in M:execute switched on? (See the toggle at
-- the top of the file.)
local function wires_modules()
  local v = vim.g.angular_auto_wire
  return v ~= false and v ~= "standalone"
end

-- Will accepting be finished off by M:execute editing the owning @NgModule rather
-- than by the in-buffer edits? Both "…is NgModule-declared" refusals end up there,
-- provided it is the CONSUMER that is module-declared -- build_component_edits
-- reports the target first, so that half has to be read off the buffer.
--
-- Whether the owning module can already see the target needs the repo-wide module
-- index, far more than the 500ms resolve gets during accept (blink drops the
-- resolved item, and with it the standalone edits, when that runs out). So the
-- popup promises the attempt and the accept notification reports the outcome.
local function wires_via_module(reason)
  if not wires_modules() then return false end
  if reason == "consumer is NgModule-declared" then return true end
  if reason ~= "target is NgModule-declared" then return false end
  local c = edits.consumer_info(0)
  return c ~= nil and c.standalone == false
end

-- Why an accepted tag would NOT be wired up, per build_component_edits' `reason`.
-- `%s` is the target class; entries that don't name it just drop the argument.
local unwired = {
  ["target is NgModule-declared"] = "NgModule-declared — import not wired (add %s to the owning module)",
  ["consumer is NgModule-declared"] = "this component is NgModule-declared — import not wired (add %s to its @NgModule)",
  ["target is this component"] = "this component's own selector — nothing to import",
  ["cursor is not in a component template"] = "not inside a component template — import not wired",
  ["not an Angular component"] = "not an Angular component — import not wired",
}

-- Is this edit the `import { X } from '…'` statement rather than the decorator
-- entry? Either can be absent (the buffer already has it), so a lone edit is told
-- apart by its text: the statement edit's newText always opens an import, while
-- the decorator entry writes a bare class name or an `imports: [` key.
local function is_import_stmt(e)
  return e.newText:match("^%s*import%s") ~= nil
end

-- One line saying what accepting this tag does to the buffer, so an item that
-- silently wires nothing says so instead of inserting a tag that won't render.
local function wiring_line(info, item_edits)
  local cls = "`" .. ((info and info.class) or "?") .. "`"
  local reason = info and info.reason
  if reason then
    if wires_via_module(reason) then
      return "→ this component is NgModule-declared — on accept " .. cls ..
        " (or a module exporting it) goes into the owning `@NgModule`"
    end
    return "→ " .. string.format(unwired[reason] or (reason .. " — import not wired"), cls)
  end
  local stmt, entry = false, false
  for _, e in ipairs(item_edits) do
    if is_import_stmt(e) then stmt = true else entry = true end
  end
  local from = (info and info.spec) and (" from `" .. info.spec .. "`") or ""
  if stmt and entry then
    return "→ imports " .. cls .. from .. " and lists it in `imports: [ ]`"
  elseif stmt then
    return "→ imports " .. cls .. from .. " (already in `imports: [ ]`)"
  elseif entry then
    -- Without a known spec, build_import_edit had nowhere to import from.
    if not (info and info.spec) then
      return "→ lists " .. cls .. " in `imports: [ ]` — no import path found, import it by hand"
    end
    return "→ lists " .. cls .. " in `imports: [ ]` (already imported)"
  end
  return "→ already imported and in `imports: [ ]` — nothing to add"
end

-- Docs popup for a tag item: the class the selector resolves to, how to get hold
-- of it, and what accepting will wire up. `info` is nil when the defining file no
-- longer parses.
local function tag_doc(sel, file, info, item_edits)
  local cls = (info and info.class) or "?"
  local parts = { "```typescript", "class " .. cls, "selector: '" .. sel .. "'", "```" }
  if info and info.spec then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "→ `import { " .. cls .. " } from '" .. info.spec .. "'`"
  end
  local facts = {}
  if info and info.standalone ~= nil then
    facts[#facts + 1] = info.standalone and "standalone" or "module-declared"
  end
  if info and info.inputs then
    facts[#facts + 1] = info.inputs .. (info.inputs == 1 and " input" or " inputs")
  end
  facts[#facts + 1] = vim.fn.fnamemodify(file, ":t")
  parts[#parts + 1] = ""
  parts[#parts + 1] = table.concat(facts, " · ")
  parts[#parts + 1] = ""
  parts[#parts + 1] = wiring_line(info, item_edits)
  return table.concat(parts, "\n")
end

-- Always incomplete. What this source answers depends on the cursor's position in
-- the template, not on the typed keyword: a complete response would be cached for
-- the rest of the insert session, so the empty answer given before `<` is typed
-- would still be the answer at `<fl-bu`. Re-querying costs a treesitter node check
-- per keystroke; outside a template that is the whole cost.
local function response(items)
  return { is_incomplete_forward = true, is_incomplete_backward = true, items = items }
end

-- The import + `Enum = Enum;` edits that make a seeded enum value resolve.
local function enum_edits(name, en)
  local out = {}
  local imp = edits.build_import_edit(0, name, en.spec, en.file)
  if imp then out[#out + 1] = imp end
  local fld = edits.build_enum_field_edit(0, name)
  if fld then out[#out + 1] = fld end
  return out
end

-- ── the three attribute modes ──────────────────────────────────────────────

-- 1. Enum-member completion: cursor after `SomeEnum.` inside a template.
local function enum_member_items(ctx, members, enum, en)
  local row = ctx.cursor[1] - 1
  local dot = ctx.line:sub(1, ctx.cursor[2]):match(".*()%.") -- 0-indexed col just after `.`
  local extra = enum_edits(enum, en)
  local items = {}
  for i, m in ipairs(members) do
    items[i] = {
      label = m,
      filterText = m,
      sortText = string.format("%03d", i),
      kind = kinds.EnumMember,
      labelDetails = { description = enum },
      insertText = m,
      textEdit = {
        newText = m,
        range = {
          start = { line = row, character = dot },
          ["end"] = { line = row, character = ctx.cursor[2] },
        },
      },
      documentation = { kind = "markdown", value = "`" .. enum .. "." .. m .. "`" },
      additionalTextEdits = #extra > 0 and extra or nil,
    }
  end
  return items
end

-- 2. Attribute-VALUE completion: by the input's declared type -- enum members
-- (`ButtonSize.SMALL`, incl. nullable `Enum | null`) or string/number-literal
-- union values (`'abc'`), when the cursor is inside `[attr]="▏"`.
local function value_items(ctx, spec)
  local items = {}
  if spec.kind == "enum" then
    local extra = enum_edits(spec.enum, spec.en)
    for i, m in ipairs(spec.en.members) do
      local full = spec.enum .. "." .. m
      items[i] = {
        label = full,
        filterText = full,
        sortText = string.format("%03d", i),
        kind = kinds.EnumMember,
        labelDetails = { description = spec.enum },
        insertText = full,
        additionalTextEdits = #extra > 0 and extra or nil,
        documentation = { kind = "markdown", value = "`" .. full .. "`" },
      }
    end
    return items
  end

  local ks = ctx.bounds.start_col
  local before1 = ks > 1 and ctx.line:sub(ks - 1, ks - 1) or ""
  for i, v in ipairs(spec.values) do
    local inner = v:gsub("^['\"]", ""):gsub("['\"]$", "")
    local shown = spec.is_binding and v or inner
    -- Binding value uses `'literal'`; if the user already typed the inner quote,
    -- don't repeat it.
    if spec.is_binding and before1 == "'" then shown = shown:sub(2) end
    items[i] = {
      label = spec.is_binding and v or inner,
      filterText = inner,
      sortText = string.format("%03d", i),
      kind = kinds.Value,
      insertText = shown,
    }
  end
  return items
end

-- 3. Attribute-NAME completion: the component's @Input/@Output list.
local function input_items(ctx, inputs, meta)
  local row = ctx.cursor[1] - 1
  -- Replace the typed keyword, extended left to swallow an already-typed binding
  -- bracket so the snippet's own brackets never double up.
  local line, ks = ctx.line, ctx.bounds.start_col -- ks: 1-indexed keyword start
  local before1 = ks > 1 and line:sub(ks - 1, ks - 1) or ""
  local before2 = ks > 2 and line:sub(ks - 2, ks - 2) or ""
  local extend = 0
  if before1 == "[" or before1 == "(" or before1 == "*" or before1 == "#" then
    extend = (before1 == "(" and before2 == "[") and 2 or 1 -- banana `[(`
  end
  local start_char = (ks - 1) - extend -- 0-indexed
  local end_char = ctx.cursor[2]       -- 0-indexed

  local items = {}
  for i, it in ipairs(inputs) do
    local text = binding(it.kind, it.name, "$1")
    local docbase = doc_value(it, meta)
    items[i] = {
      label = it.name,
      filterText = it.name,
      sortText = it.name,
      kind = kind_icon(it),
      labelDetails = { description = it.type or it.kind },
      insertText = text,
      insertTextFormat = Snippet,
      textEdit = {
        newText = text,
        range = {
          start = { line = row, character = start_char },
          ["end"] = { line = row, character = end_char },
        },
      },
      documentation = { kind = "markdown", value = docbase },
      -- Round-tripped to resolve() to seed enum values + auto-import.
      data = { name = it.name, prop = it.prop, kind = it.kind, type = it.type, doc = it.doc, docbase = docbase },
    }
  end
  return items
end

-- Modes 1-3, tried in order. Split out of get_completions so the tag mode can go
-- in front of them without adding a fourth level of nesting to this chain.
local function attr_completions(ctx, callback)
  completion.enum_members(function(members, enum, en)
    if members then
      return callback(response(enum_member_items(ctx, members, enum, en)))
    end
    completion.value_completions(function(spec)
      if spec then
        return callback(response(value_items(ctx, spec)))
      end
      completion.inputs(function(inputs, meta)
        if not inputs or #inputs == 0 then return callback(response({})) end
        callback(response(input_items(ctx, inputs, meta)))
      end)
    end)
  end)
end

function M:get_completions(ctx, callback)
  callback = vim.schedule_wrap(callback)

  -- All four modes read an inline template, and in a .ts file the cursor is
  -- usually not in one. Answering here is what keeps the per-keystroke cost of
  -- this source in ordinary TypeScript down to a single treesitter node walk.
  if not context.in_template(vim.api.nvim_get_current_buf()) then
    return callback(response({}))
  end

  -- 0. Component-TAG completion: cursor in `<fl-bu▏` inside an inline template.
  -- Tried first because at that point there is no attribute or value context for
  -- the later modes to read.
  completion.tag_completions(function(tags, meta)
    if not tags then return attr_completions(ctx, callback) end

    -- A bare `<` matches the whole ~4.8k-selector index, on every `<` in a
    -- template -- `<div` included, which will never want this menu. Answer empty
    -- and let blink come back the moment a letter narrows it.
    if (meta.prefix or "") == "" then
      return callback({ is_incomplete_forward = true, is_incomplete_backward = false, items = {} })
    end

    local row = ctx.cursor[1] - 1
    local items = {}
    for i, t in ipairs(tags) do
      local text = tag_snippet(t.selector)
      items[i] = {
        label = t.selector,
        filterText = t.selector,
        sortText = t.selector,
        kind = kinds.Class,
        labelDetails = { description = t.dir },
        insertText = text,
        insertTextFormat = Snippet,
        textEdit = {
          newText = text,
          range = {
            -- Starts on the `<` the user already typed, so the snippet's own `<`
            -- replaces it rather than doubling up — blink's keyword begins after
            -- the bracket, the same left-extension the bindings above rely on.
            start = { line = row, character = meta.lt_col },
            ["end"] = { line = row, character = ctx.cursor[2] },
          },
        },
        -- Round-tripped to resolve() for the class/import docs.
        data = { file = t.file, selector = t.selector },
      }
    end
    callback(response(items))
  end)
end

-- Enrich the focused item: a tag gets its component's class, its auto-import
-- edits and a line saying whether they will fire; an input typed as an exported
-- enum gets its binding value seeded with `Enum.` and, on accept, the enum
-- imported. Outputs are event handlers, not enum values, so they're untouched.
function M:resolve(item, callback)
  callback = vim.schedule_wrap(callback)
  local d = item.data
  if not d then return callback(item) end

  -- Tag items are the only ones carrying a file. build_component_edits works out
  -- what makes the component reachable from this consumer, and refuses for the
  -- NgModule and self-reference cases. Only the focused item gets here, so its
  -- parse is paid ~once per keystroke, not 4.8k times per menu.
  if d.file and not d.type then
    local item_edits, info = edits.build_component_edits(0, d.file)
    return callback({
      -- The snippet textEdit is left untouched, so blink's deep-merge keeps it.
      documentation = { kind = "markdown", value = tag_doc(d.selector, d.file, info, item_edits) },
      additionalTextEdits = #item_edits > 0 and item_edits or nil,
    })
  end

  if not d.type or d.kind == "output" then return callback(item) end

  component.resolve_enum(d.type, function(en)
    if not en then return callback(item) end
    local name = en.name -- normalized enum name (d.type may be `Enum | null`)

    local extra = { "", "**enum " .. name .. "**" }
    if en.spec then extra[#extra + 1] = "→ `import { " .. name .. " } from '" .. en.spec .. "'`" end
    if #en.members > 0 then
      local shown = {}
      for i = 1, math.min(#en.members, 12) do
        shown[i] = "`" .. name .. "." .. en.members[i] .. "`"
      end
      extra[#extra + 1] = table.concat(shown, " · ") .. (#en.members > 12 and " …" or "")
    end

    local applied = enum_edits(name, en)
    callback({
      -- range is preserved from the original item by blink's deep-merge.
      textEdit = { newText = binding(d.kind, d.name, name .. ".$1") },
      documentation = { kind = "markdown", value = d.docbase .. "\n" .. table.concat(extra, "\n") },
      -- On accept: import the enum AND expose it on the class (`Enum = Enum;`), so
      -- the seeded `Enum.MEMBER` actually resolves in the template.
      additionalTextEdits = #applied > 0 and applied or nil,
    })
  end)
end

-- ── accepting a tag: the file the user isn't looking at ────────────────────

-- Where to say the edit landed, relative to the source root the data layer
-- indexes under.
local function rel_path(file)
  local root = search.src_root(file) or file:match("(.*/webapp)/")
  return root and file:sub(#root + 2) or vim.fn.fnamemodify(file, ":t")
end

-- Apply a `kind = "module"` plan to the file it names, and say so. Saving is
-- conditional: an already-modified buffer holds the user's own unsaved work, so
-- it is edited and handed back; a clean one is written because nothing else will
-- -- the file is off screen and the change would be lost to the next :bd or
-- checkout. noautocmd keeps format-on-save off it, which would otherwise bury a
-- two-line wiring change in a whole-file diff.
local function apply_plan(plan)
  local bufnr = vim.fn.bufadd(plan.file)
  vim.fn.bufload(bufnr)
  local dirty = vim.bo[bufnr].modified
  vim.lsp.util.apply_text_edits(plan.edits, bufnr, "utf-8")
  -- Whether the write happened, not whether it was attempted: a failed one leaves
  -- the same modified buffer as the dirty case, and the message has to say so.
  local saved = false
  if not dirty then
    saved = pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd("noautocmd silent write") end)
  end
  vim.notify(
    plan.summary .. " — " .. rel_path(plan.file) .. (saved and " (saved)" or " (changed, left unsaved)"),
    vim.log.levels.INFO,
    { title = "Angular" }
  )
end

-- Accepting an item. blink's `default_implementation` applies the item itself --
-- textEdit, snippet and the additionalTextEdits resolve attached -- and
-- everything after it is the second file. `callback` completes blink's accept
-- task, so it must fire exactly once down every path, thrown errors included.
function M:execute(ctx, item, callback, default_implementation)
  -- First, always: the tag and its snippet are what the user is waiting on, and
  -- the cross-file work below must never be in front of them.
  default_implementation()

  local d = item.data
  -- Tag items are the only ones carrying a file and no type; the binding items
  -- carry both, and have nothing to wire outside this buffer.
  if not d or not d.file or d.type then return callback() end
  if not wires_modules() then return callback() end

  local done = false
  local function finish()
    if done then return end
    done = true
    callback()
  end
  -- The plan reads a repo-wide index and parses another file. A throw there --
  -- synchronously, or later from the index callback where no caller is left to
  -- catch it -- would strand the accept task unresolved. Asked for after the
  -- insert, which is safe: the plan derives from the enclosing component.
  local ok = pcall(edits.build_ngmodule_plan, 0, d.file, function(plan)
    if plan and plan.kind == "module" then pcall(apply_plan, plan) end
    finish() -- a "none" plan says nothing: the docs popup already explained it
  end)
  if not ok then finish() end
end

return M
