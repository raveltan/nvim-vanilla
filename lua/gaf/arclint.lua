-- Reads fl-gaf's .arclint so the editor reports PHP lint the same way
-- `arc lint` does. Two things live there that nvim-lint has no concept of:
--
--   1. the file to ruleset split. src2/ is linted by the `phpcs-src2` linter
--      with phpcs_gaf-src2.xml, everything else by `phpcs` with phpcs_gaf.xml.
--   2. per-sniff severity overrides, which fl-gaf uses heavily. 16 sniffs on the
--      non-src2 linter and 1 on src2 are downgraded to "advice", so arc shows
--      them but they never block. phpcs itself still emits them as errors, so
--      without this map the editor paints 16 red errors arc considers noise.
--
-- Parsed from the file rather than transcribed into Lua so the two cannot drift.
-- A repo-side change to .arclint takes effect on the next save.
local paths = require("gaf.paths")

local M = {}

-- Arc's five severities (ArcanistLintSeverity) mapped onto vim's four.
-- "disabled" has no counterpart, so it maps to false and consumers drop those
-- diagnostics the way arc does.
local ARC_TO_VIM = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  autofix = vim.diagnostic.severity.INFO,
  advice = vim.diagnostic.severity.HINT,
  disabled = false,
}

local cache = { mtime = nil, data = nil }

-- A broken or missing .arclint yields nil, so every caller degrades to "no
-- overrides" rather than erroring on every save.
local function config()
  local file = paths.fl_gaf .. "/.arclint"
  local stat = vim.uv.fs_stat(file)
  if not stat then
    cache = { mtime = nil, data = nil }
    return nil
  end
  -- Size as well as mtime: a same-second edit would otherwise be missed.
  local stamp = stat.mtime.sec .. ":" .. stat.size
  if cache.mtime == stamp then return cache.data end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  end)
  cache = { mtime = stamp, data = ok and decoded or nil }
  return cache.data
end

--- Mirrors the include/exclude regexes of the two flarc-phpcs linters as plain
--- prefix tests rather than translated PCRE. The patterns involved are anchored
--- literals, and a general PCRE to Lua translation would be a far bigger
--- liability than the two lines it saves.
local function phpcs_linter(relpath)
  if not relpath then return "phpcs" end
  return vim.startswith(relpath, "src2/") and "phpcs-src2" or "phpcs"
end

function M.phpcs_standard(relpath)
  local linter = phpcs_linter(relpath)
  local conf = config()
  local standard = conf
    and conf.linters
    and conf.linters[linter]
    and conf.linters[linter]["phpcs.standard"]
  return paths.fl_gaf .. "/" .. (standard or "phpcs_gaf.xml")
end

-- Prefixes .arclint excludes from the phpcs linters. support/flarc is PHP 7.4
-- and would fail the 8.1 PHPCompatibility sniffs, and public/static and
-- public/build are generated.
local EXCLUDED_PREFIXES = { "support/flarc/", "public/static/", "public/build/" }
local EXCLUDED_FILES = { ["phpstan-baseline.php"] = true, ["phpstan-baseline-src2.php"] = true }

function M.phpcs_applies(relpath)
  if not relpath then return false end
  if not relpath:match("%.php$") then return false end
  if EXCLUDED_FILES[relpath] then return false end
  for _, prefix in ipairs(EXCLUDED_PREFIXES) do
    if vim.startswith(relpath, prefix) then return false end
  end
  return true
end

--- Keyed `PHPCS.E.<sniff>` / `PHPCS.W.<sniff>`, with false where arc has the
--- sniff disabled. Only the exact-match `severity` map is honoured. .arclint
--- also supports `severity.rules` with regex keys, but fl-gaf sets none for
--- phpcs and silently half-applying it would be worse than ignoring it.
function M.phpcs_severities(relpath)
  local conf = config()
  local block = conf and conf.linters and conf.linters[phpcs_linter(relpath)]
  local raw = block and block.severity
  if not raw then return {} end
  local map = {}
  for code, arc in pairs(raw) do
    local severity = ARC_TO_VIM[arc]
    if severity ~= nil then map[code] = severity end
  end
  return map
end

return M
