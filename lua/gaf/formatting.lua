local arclint = require("gaf.arclint")
local paths = require("gaf.paths")

local M = {}

-- Merged over conform's builtin php_cs_fixer (inherit defaults to true), so
-- stdin=false and the rest come from the builtin and only the fl-gaf binary and
-- --config differ. args stays explicit because the options must follow the `fix`
-- subcommand and prepend_args would put them before it.
function M.php_cs_fixer_formatter()
  return {
    -- fl-gaf files only. Without this, saving a PHP file in any other project
    -- under GAF=1 reformats it with fl-gaf's ruleset, since the args below
    -- hard-code --config and cwd, and a missing binary is a hard error on every
    -- save.
    condition = function(_, ctx)
      return paths.gaf_relpath(ctx.buf) ~= nil
    end,
    command = paths.fl_gaf .. "/support/php-cs-fixer/vendor/bin/php-cs-fixer",
    args = function(_, ctx)
      -- src2 has its own config. .php-cs-fixer.dist.php's Finder excludes src2,
      -- but --path-mode defaults to `override` so an explicit $FILENAME is
      -- formatted anyway with the wrong ruleset, missing the six src2-only rules
      -- (global_namespace_import, ordered_class_elements, ...), and saving then
      -- diverged from `composer fix:php-cs-fixer:all`.
      local relpath = paths.gaf_relpath(ctx.buf)
      local config = (relpath and vim.startswith(relpath, "src2/"))
        and "/.php-cs-fixer-src2.dist.php"
        or "/.php-cs-fixer.dist.php"
      return {
        "fix",
        "--config=" .. paths.fl_gaf .. config,
        "--no-interaction",
        "--quiet",
        "$FILENAME",
      }
    end,
    -- Both configs are cwd-sensitive even though --path-mode defaults to
    -- `override`: the Finder is still constructed, and the src2 one does
    -- `->in('src2')`, which aborts with `The "src2" directory does not exist`
    -- from anywhere else. Pinning also puts the .cache/php-cs-fixer/ files inside
    -- the repo, where CI expects them, instead of wherever nvim was started.
    cwd = function() return paths.fl_gaf end,
  }
end

-- nvim-lint evaluates function elements of an args list per run, and a function
-- used as `args` itself is silently dropped so phpcs would run bare. The
-- per-buffer ruleset choice therefore has to be one entry, not a computed table.
function M.phpcs_args()
  return {
    "-q",
    "--report=json",
    function() return "--standard=" .. arclint.phpcs_standard(paths.gaf_relpath(0)) end,
    -- Without this phpcs sees the buffer as "STDIN" with no path, so every
    -- <exclude-pattern> in the rulesets (vendor/*, src2/Traits/GafThrift/*,
    -- src/Core/Test/Thrift/ApiClient/*) stops matching. Repo-relative, matching
    -- how the rulesets and .arclint express paths.
    function() return "--stdin-path=" .. (paths.gaf_relpath(0) or vim.fn.expand("%:p")) end,
    "-", -- phpcs requires this last for stdin
  }
end

--- The builtin parser maps phpcs ERROR/WARNING straight onto vim ERROR/WARN,
--- which paints 16 sniffs red that arc treats as advice. Arc's message code
--- (`PHPCS.E.<sniff>` / `PHPCS.W.<sniff>`, per FlarcPhpcsLinter) is rebuilt from
--- the diagnostic and re-graded, and sniffs arc disables are dropped.
function M.phpcs_parser(builtin)
  return function(output, bufnr, ...)
    local diagnostics = builtin(output, bufnr, ...)
    local severities = arclint.phpcs_severities(paths.gaf_relpath(bufnr))
    if vim.tbl_isempty(severities) then return diagnostics end
    local kept = {}
    for _, d in ipairs(diagnostics) do
      local prefix = d.severity == vim.diagnostic.severity.ERROR and "E" or "W"
      local override = severities["PHPCS." .. prefix .. "." .. (d.code or "")]
      if override ~= false then
        if override then d.severity = override end
        table.insert(kept, d)
      end
    end
    return kept
  end
end

return M
