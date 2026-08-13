-- Context-smart rename backends for <leader>cr (see core/keymaps.lua). Each entry
-- point returns false when the cursor context doesn't match, so the caller falls
-- through to the next backend and finally to LSP symbol rename.
--
-- Class rename is component-scoped and cross-file. From a template (html, or an
-- Angular inline template in .ts) it also rewrites the component's styleUrls
-- stylesheets, resolving scss `&`-suffix nesting (.Header { &-main }) via
-- core/scss.lua. From a scss buffer (cursor on `.X` or on `&-suffix`) it rewrites
-- the sibling template instead. Deeper `&` nests cascade, so Header-main-title
-- follows Header-main.

local M = {}

local CSS_FT = { css = true, scss = true, less = true, sass = true }

-- Token under the cursor including hyphens (`btn-primary`), scanned rather than
-- read through iskeyword because html buffers leave `-` out of it. Returns the
-- token, its 1-based start col, and the line.
local function token_at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  col = col + 1 -- 1-based char under cursor
  local init = 1
  while true do
    local s, e = line:find("[%w_%-]+", init)
    if not s or s > col then return nil end
    if col <= e then return line:sub(s, e), s, line end
    init = e + 1
  end
end

-- True when 1-based col `s` sits inside the quoted value of a class-like attribute
-- on `line`. The name pattern covers `class`, `className` and `[ngClass]` (where
-- the match starts at `Class`), and `{?` admits the JSX `className={"..."}` brace.
-- Single-line attributes only.
local function in_class_attr(line, s)
  local init = 1
  while true do
    local _, qpos, quote = line:find("[Cc]lass[%w]*%]?%s*=%s*{?([\"'])", init)
    if not qpos then return false end
    local close = line:find(quote, qpos + 1, true)
    local vend = (close or (#line + 1)) - 1
    if s > qpos and s <= vend then return true end
    init = qpos + 1
  end
end

-- Class name under the cursor, or nil. In a CSS buffer that is a `.foo` or
-- `&-suffix` selector, the latter resolved to its full concatenated name. In a
-- markup buffer it is a token inside a class attribute or a `[class.foo]` binding.
local function class_token()
  local tok, s, line = token_at_cursor()
  if not tok then return nil end
  if CSS_FT[vim.bo.filetype] then
    local prev = line:sub(s - 1, s - 1)
    if prev == "." then return tok end
    if prev == "&" then
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      return require("core.scss").amp_class_at(lines, row, tok)
    end
    return nil
  end
  if in_class_attr(line, s) then return tok end
  if line:sub(1, s - 1):match("%[class%.$") then return tok end
  return nil
end

-- `%` is the only character special in a gsub replacement string.
local function rep_escape(str)
  return (str:gsub("%%", "%%%%"))
end

local function styleurls_from(text, dir)
  local rels = {}
  local arr = text:match("styleUrls%s*:%s*%[(.-)%]")
  if arr then
    for p in arr:gmatch("['\"]([^'\"]+)['\"]") do rels[#rels + 1] = p end
  end
  local single = text:match("styleUrl%s*:%s*['\"]([^'\"]+)['\"]")
  if single then rels[#rels + 1] = single end
  local out = {}
  for _, rel in ipairs(rels) do
    local abs = vim.fs.normalize(dir .. "/" .. rel)
    if vim.uv.fs_stat(abs) then out[#out + 1] = abs end
  end
  return out
end

-- Component-scoped file set for the rename, derived from the current buffer:
-- templates (html, or .ts with an inline template) and stylesheets. A non-Angular
-- buffer ends up with just itself, plus a same-stem sibling when one exists.
local function scope()
  local path = vim.api.nvim_buf_get_name(0)
  local ft = vim.bo.filetype
  local dir = vim.fs.dirname(path)
  local stem = path:gsub("%.[^%.]+$", "")
  local templates, styles = {}, {}

  if ft == "typescript" then
    templates[1] = path
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    styles = styleurls_from(text, dir)
    local turl = text:match("templateUrl%s*:%s*['\"]([^'\"]+)['\"]")
    if turl then
      local abs = vim.fs.normalize(dir .. "/" .. turl)
      if vim.uv.fs_stat(abs) then templates[#templates + 1] = abs end
    end
  elseif CSS_FT[ft] then
    styles[1] = path
    for _, ext in ipairs({ ".html", ".ts" }) do
      if vim.uv.fs_stat(stem .. ext) then
        templates[1] = stem .. ext
        break
      end
    end
  else
    templates[1] = path
    local ts = stem .. ".ts"
    if vim.uv.fs_stat(ts) then
      styles = styleurls_from(table.concat(vim.fn.readfile(ts), "\n"), vim.fs.dirname(ts))
    end
    if #styles == 0 and vim.uv.fs_stat(stem .. ".scss") then
      styles[1] = stem .. ".scss"
    end
  end
  return templates, styles
end

-- Apply `map` (old class -> new class) to class-like attribute values, Angular
-- `[class.x]` bindings, and `.x` selectors inside <style> blocks. Bare JS property
-- access such as `obj.active` is never touched.
local function patch_template_lines(lines, map)
  local out, changed, total = {}, false, 0
  local in_style = false
  for i, line in ipairs(lines) do
    local l = line
    for oc, nc in pairs(map) do
      local pat = "%f[%w_%-]" .. vim.pesc(oc) .. "%f[^%w_%-]"
      local rep = rep_escape(nc)
      l = l:gsub('([Cc]lass[%w]*%]?%s*=%s*{?)(["\'])(.-)%2', function(pre, q, val)
        local v, n = val:gsub(pat, rep)
        total = total + n
        return pre .. q .. v .. q
      end)
      local n
      l, n = l:gsub("%[class%." .. vim.pesc(oc) .. "%]", "[class." .. rep .. "]")
      total = total + n
      if in_style then
        l, n = l:gsub("%." .. vim.pesc(oc) .. "%f[^%w_%-]", "." .. rep)
        total = total + n
      end
    end
    if line:match("<style") then in_style = true end
    if line:match("</style>") then in_style = false end
    if l ~= line then changed = true end
    out[i] = l
  end
  return changed and out or nil, total
end

-- Run `fn(lines)` against the buffer for `path`, loading it on demand, and write
-- when it returns replacement lines. Matches the LSP-rename autosave.
local function edit_file(path, fn)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local lines, count = fn(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent keepalt write") end)
  end
  return lines ~= nil, count
end

local function do_class_rename(old, new)
  local scss = require("core.scss")

  -- An unnamed buffer has no file scope to resolve, so patch it without writing.
  if vim.api.nvim_buf_get_name(0) == "" then
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local out, _, warnings
    if CSS_FT[vim.bo.filetype] then
      out, _, warnings = scss.rename(lines, old, new)
    else
      out = patch_template_lines(lines, { [old] = new })
    end
    if out then vim.api.nvim_buf_set_lines(0, 0, -1, false, out) end
    vim.notify(("Renamed .%s → .%s in buffer%s"):format(old, new,
      warnings and #warnings > 0 and ("\n" .. table.concat(warnings, "\n")) or ""))
    return
  end

  local templates, styles = scope()
  local map = { [old] = new }
  local warnings, changed_files = {}, {}
  local any_style_handled = #styles == 0 -- no stylesheets in scope, so template-only

  for _, path in ipairs(styles) do
    local changed = edit_file(path, function(lines)
      local out, m, warns, handled = scss.rename(lines, old, new)
      for k, v in pairs(m) do map[k] = v end
      vim.list_extend(warnings, warns)
      any_style_handled = any_style_handled or handled
      return out
    end)
    if changed then changed_files[#changed_files + 1] = vim.fn.fnamemodify(path, ":t") end
  end

  if not any_style_handled then
    vim.notify(
      ("No definition of .%s could be rewritten in %s so the template was left untouched.\n%s")
        :format(old, table.concat(vim.tbl_map(function(p) return vim.fn.fnamemodify(p, ":t") end, styles), ", "),
          table.concat(warnings, "\n")),
      vim.log.levels.ERROR)
    return
  end

  local total = 0
  for _, path in ipairs(templates) do
    local changed, n = edit_file(path, function(lines)
      return patch_template_lines(lines, map)
    end)
    if changed then
      total = total + n
      changed_files[#changed_files + 1] = vim.fn.fnamemodify(path, ":t")
    end
  end

  local cascades = {}
  for k, v in pairs(map) do
    if k ~= old then cascades[#cascades + 1] = k .. " → " .. v end
  end
  local msg = ("Renamed .%s → .%s in: %s"):format(old, new,
    #changed_files > 0 and table.concat(changed_files, ", ") or "nothing (no occurrences)")
  if #cascades > 0 then msg = msg .. "\ncascaded: " .. table.concat(cascades, ", ") end
  if #warnings > 0 then msg = msg .. "\n" .. table.concat(warnings, "\n") end
  vim.notify(msg, #warnings > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

-- Repo-wide class renames deliberately stay out of scope. They go through
-- :grep + :cdo (<leader>xr), where the diff is reviewable.
function M.class_rename()
  local old = class_token()
  if not old then return false end
  vim.ui.input({ prompt = "Rename class: ", default = old }, function(new)
    if not new or new == "" or new == old then return end
    do_class_rename(old, new)
  end)
  return true
end

-- Tag rename via tagmatch. An uppercase name in a buffer with a rename-capable LSP
-- is left to LSP rename, because a JSX/TSX/Vue component needs its definition and
-- every usage updated, where tagmatch would touch only this tag pair.
function M.tag_rename()
  local ok, tagmatch = pcall(require, "tagmatch")
  if not ok then return false end
  local old = tagmatch.rename_info()
  if not old then return false end
  if old:match("^%u")
      and #vim.lsp.get_clients({ bufnr = 0, method = "textDocument/rename" }) > 0 then
    return false
  end
  return tagmatch.rename()
end

-- Raw textDocument/rename rather than vim.lsp.buf.rename, because the PHP servers
-- report a rename range that starts after the `$` sigil. The cursor is nudged past
-- the sigil and the sigil is re-attached to newName by hand.
function M.lsp_rename()
  local bufnr = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/rename" })
  if #clients == 0 then
    vim.notify("No LSP client supports rename", vim.log.levels.WARN)
    return
  end
  local client = clients[1]

  local orig_cursor = nil
  if vim.bo[bufnr].filetype == "php" then
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    if line:sub(col + 1, col + 1) == "$" then
      orig_cursor = { row, col }
      vim.api.nvim_win_set_cursor(0, { row, col + 1 })
    end
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  local cword = vim.fn.expand("<cword>")
  local is_php = vim.bo[bufnr].filetype == "php"
  local php_is_var = false
  if is_php then
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    if line:sub(1, col + 1):match("%$[%w_]*$") then php_is_var = true end
    cword = cword:gsub("^%$", "")
  end

  vim.ui.input({ prompt = "Rename: ", default = cword }, function(new_name)
    local function restore_cursor()
      if orig_cursor then pcall(vim.api.nvim_win_set_cursor, 0, orig_cursor) end
    end
    if not new_name or new_name == "" then return restore_cursor() end
    if is_php then new_name = new_name:gsub("^%$", "") end
    if new_name == cword then return restore_cursor() end
    params.newName = php_is_var and ("$" .. new_name) or new_name
    client:request("textDocument/rename", params, function(err, result)
      if err then
        vim.notify(string.format("Rename failed: %s (code=%s data=%s)",
          err.message, tostring(err.code), vim.inspect(err.data)), vim.log.levels.ERROR)
        return
      end
      if not result then
        vim.notify("Language server returned no rename result", vim.log.levels.WARN)
        return
      end
      vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)
      vim.cmd("silent! wall")
    end, bufnr)
  end)
end

function M.rename()
  if M.class_rename() then return end
  if M.tag_rename() then return end
  M.lsp_rename()
end

return M
