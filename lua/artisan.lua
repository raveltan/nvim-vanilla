-- Laravel project support for the non-GAF profile: pint/blade-formatter
-- formatting and phpstan/larastan linting.
--
-- Named `artisan`, not `laravel`, because a module under lua/ shadows any plugin
-- of the same name, so a lua/laravel.lua here would silently stop laravel.nvim
-- booting if it were ever added.
--
-- Every entry point resolves the project from the buffer's path rather than from
-- one checkout decided at startup, because several Laravel projects can be open
-- in one session and none may be open at all. The nil returned when there is no
-- project keeps all of this inert inside fl-gaf, which has no `artisan` file, so
-- the GAF php-cs-fixer/phpcs pipeline is never touched.
local M = {}

-- dir -> root | false. vim.fs.root walks the tree on every call and these
-- helpers run per format and per lint, so misses are cached as `false` too, not
-- just hits.
local roots = {}

local function buf_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  -- Unnamed buffers and URI-style names (fugitive://, oil://, dbui) have no
  -- usable directory. Falling back to cwd keeps :LaravelPhpstan working from a
  -- scratch buffer.
  if name == "" or name:match("^%w%w+://") then return vim.fn.getcwd() end
  return vim.fs.dirname(name)
end

function M.root(from)
  local dir = type(from) == "string" and from or buf_dir(from)
  local cached = roots[dir]
  if cached ~= nil then return cached or nil end
  local found = vim.fs.root(dir, "artisan")
  roots[dir] = found or false
  return found
end

--- The project's own vendor/bin or node_modules/.bin comes before $PATH because
--- it matches composer.json / package.json and so is the version CI will use.
--- Always absolute: a cwd-relative "vendor/bin/pint" breaks the moment nvim was
--- not started from the project root, the trap documented for phpcs in
--- lua/core/plugins.lua.
function M.bin(name, root)
  root = root or M.root()
  if root then
    for _, dir in ipairs({ "/vendor/bin/", "/node_modules/.bin/" }) do
      local p = root .. dir .. name
      if vim.uv.fs_stat(p) then return p end
    end
  end
  if vim.fn.executable(name) == 1 then return vim.fn.exepath(name) end
  return nil
end

-- ── formatting ──────────────────────────────────────────────────────────────
--
-- Every formatter here is condition-guarded on the project actually shipping the
-- tool, so a global `pint` on $PATH never reformats an unrelated PHP repo to
-- Laravel's style. When no condition matches, conform falls through to
-- `lsp_format = "fallback"` and the PHP LSP formats instead.

-- conform passes ctx.dirname, so resolution is per buffer. One session can
-- format a Laravel repo with pint and a plain PHP repo with php-cs-fixer without
-- any global state.
local function project_bin(name, ctx)
  local root = M.root(ctx.dirname)
  if not root then return nil end
  return M.bin(name, root), root
end

function M.formatters()
  return {
    -- pint is php-cs-fixer with Laravel's ruleset baked in. The builtin already
    -- finds vendor/bin/pint by walking up from the buffer, so the condition is
    -- only there to stop a globally installed pint touching non-Laravel PHP.
    pint = {
      condition = function(_, ctx)
        return project_bin("pint", ctx) ~= nil
      end,
      cwd = function(_, ctx)
        return M.root(ctx.dirname)
      end,
    },

    -- Fallback for Laravel projects that predate pint and still carry a
    -- php-cs-fixer config. Guarded on the config file, not just the binary,
    -- because php-cs-fixer with no config rewrites to its own default ruleset.
    php_cs_fixer = {
      condition = function(_, ctx)
        local root = M.root(ctx.dirname)
        if not root then return false end
        for _, name in ipairs({ ".php-cs-fixer.php", ".php-cs-fixer.dist.php", ".php_cs", ".php_cs.dist" }) do
          if vim.uv.fs_stat(root .. "/" .. name) then return true end
        end
        return false
      end,
    },

    -- The builtin only looks for `blade-formatter` on $PATH, which misses the
    -- common case of it being a project devDependency.
    ["blade-formatter"] = {
      command = function(_, ctx)
        return (project_bin("blade-formatter", ctx)) or "blade-formatter"
      end,
      condition = function(_, ctx)
        return project_bin("blade-formatter", ctx) ~= nil
      end,
      cwd = function(_, ctx)
        return M.root(ctx.dirname)
      end,
    },
  }
end

function M.formatters_by_ft()
  return {
    php = { "pint", "php_cs_fixer", stop_after_first = true },
    blade = { "blade-formatter" },
  }
end

-- ── phpstan / larastan ──────────────────────────────────────────────────────
--
-- Guarded three ways before it will ever spawn:
--   1. the buffer must sit under an `artisan` root, so fl-gaf keeps phpcs and
--      never starts a second, much slower analyser
--   2. the project must ship the binary
--   3. the project must ship a phpstan config. With none, phpstan analyses
--      nothing, exits non-zero and produces no JSON

local CONFIGS = { "phpstan.neon", "phpstan.neon.dist", "phpstan.dist.neon" }

local function config_file(root)
  for _, name in ipairs(CONFIGS) do
    local p = root .. "/" .. name
    if vim.uv.fs_stat(p) then return p end
  end
  return nil
end

local broken_include_reported = {}

--- A missing `includes:` target, usually a stale `vendor/larastan/...` path
--- after a composer change, makes phpstan exit 1 while writing nothing to either
--- stdout or stderr. There is no output to parse and no stream to watch, so the
--- run looks exactly like a clean file and is caught here instead, before
--- spawning a process that cannot succeed.
local function missing_include(config)
  local ok, lines = pcall(vim.fn.readfile, config)
  if not ok then return nil end
  local dir = vim.fs.dirname(config)
  local in_includes = false
  for _, line in ipairs(lines) do
    if line:match("^includes:") then
      in_includes = true
    elseif in_includes then
      local entry = line:match("^%s+%-%s*(.+)%s*$")
      if not entry then
        if line:match("^%S") then in_includes = false end
      -- Resolving neon parameter expansion (%rootDir%,
      -- %currentWorkingDirectory%) needs phpstan itself.
      elseif not entry:find("%%") then
        entry = entry:gsub("^['\"]", ""):gsub("['\"]$", "")
        local path = entry:sub(1, 1) == "/" and entry or (dir .. "/" .. entry)
        if not vim.uv.fs_stat(path) then return entry end
      end
    end
  end
  return nil
end

local function resolve(bufnr)
  local root = M.root(bufnr)
  if not root then return nil end
  local bin = M.bin("phpstan", root)
  if not bin then return nil end
  local config = config_file(root)
  if not config then return nil end

  local missing = missing_include(config)
  if missing then
    if not broken_include_reported[config .. missing] then
      broken_include_reported[config .. missing] = true
      vim.notify(
        ("phpstan: %s includes a file that does not exist: %s\nphpstan would exit silently, so it is not being run.")
          :format(vim.fn.fnamemodify(config, ":."), missing),
        vim.log.levels.WARN
      )
    end
    return nil
  end

  return { bin = bin, config = config, root = root }
end

-- Bootstrapping larastan loads the whole framework, so the default 128M dies on
-- any real app. `analyse` is phpstan's own spelling, not the `analyze` alias the
-- nvim-lint builtin uses.
local BASE_ARGS = { "analyse", "--error-format=json", "--no-progress", "--memory-limit=2G" }

-- PHPStan 2.x sniffs these and switches to an "AI agent" output shape that
-- OVERRIDES --error-format=json (see its AiAgentDetector::ENV_VARS). Neovim
-- launched from an agent-managed terminal therefore inherits the marker and gets
-- zero diagnostics on every save, plus one unparseable-output warning, so they
-- are stripped for the phpstan process only.
local AI_AGENT_VARS = {
  "AI_AGENT", "AMP_CURRENT_THREAD_ID", "AUGMENT_AGENT", "CLAUDECODE", "CLAUDE_CODE",
  "CLAUDE_CODE_ENTRYPOINT", "CODEX_SANDBOX", "CODEX_THREAD_ID", "CURSOR_AGENT",
  "CURSOR_TRACE_ID", "GEMINI_CLI", "OPENCODE", "OPENCODE_CLIENT", "REPL_ID",
}

--- Returned whole because both consumers replace the child environment rather
--- than merging into it.
local function clean_env()
  local env = vim.fn.environ()
  for _, name in ipairs(AI_AGENT_VARS) do
    env[name] = nil
  end
  return env
end

--- phpstan writes diagnostics to stdout but bootstrap failures to stderr, so the
--- linter reads both (stream = "both") and the JSON has to be located inside the
--- combined text. Reading stdout alone made the most common failure, a bad
--- `includes:` or a missing extension, completely silent.
local function split_output(output)
  local start = output:find('{"totals"', 1, true) or output:find("{", 1, true)
  if not start then return nil, output end
  return output:sub(start), start > 1 and output:sub(1, start - 1) or nil
end

local function args(ctx)
  local out = vim.list_extend({}, BASE_ARGS)
  vim.list_extend(out, { "-c", ctx.config })
  return out
end

--- Points nvim-lint's phpstan linter at the buffer's project instead of cwd. The
--- builtin resolves `vendor/bin/phpstan` with fnamemodify(':p'), relative to cwd,
--- the exact failure already documented for phpcs in lua/core/plugins.lua, a
--- spawn error on every save when nvim was not started from the project root.
function M.configure_lint(lint)
  local phpstan = lint.linters.phpstan

  phpstan.cmd = function()
    local ctx = resolve(0)
    -- try_lint() is only ever called with "phpstan" when resolve() succeeded
    -- (see M.php_linters), so nil here means the project changed under us.
    return ctx and ctx.bin or "phpstan"
  end

  -- `args` must stay a LIST: nvim-lint does vim.tbl_map over it, so a function
  -- in its place is silently dropped, phpstan then runs with no arguments, emits
  -- non-JSON, and every save reports zero diagnostics. Only the elements may be
  -- functions, each evaluated with cwd set to the lint cwd.
  phpstan.args = vim.list_extend(vim.list_extend({}, BASE_ARGS), {
    "-c",
    function()
      local ctx = resolve(0)
      return ctx and ctx.config or "phpstan.neon"
    end,
  })

  phpstan.env = clean_env()
  phpstan.stream = "both"

  -- The builtin parser calls vim.json.decode unguarded, so any non-JSON (a PHP
  -- fatal while bootstrapping the container, a missing larastan extension, a
  -- memory abort) throws inside the lint callback and repeats on every save.
  -- Each distinct failure is reported once instead.
  local builtin_parser = phpstan.parser
  local reported = {}
  local function warn_once(msg)
    if reported[msg] then return end
    reported[msg] = true
    vim.notify("phpstan: " .. msg, vim.log.levels.WARN)
  end

  phpstan.parser = function(output, bufnr)
    if output == nil or vim.trim(output) == "" then return {} end
    local json, noise = split_output(output)
    if not json then
      return warn_once(vim.trim(noise):sub(1, 400)) or {}
    end
    local ok, diagnostics = pcall(builtin_parser, json, bufnr)
    if not ok then
      return warn_once("unparseable output\n" .. vim.trim(output):sub(1, 400)) or {}
    end
    return diagnostics
  end
end

--- Called from the BufWritePost dispatch in lua/core/plugins.lua rather than
--- declared in linters_by_ft, because eligibility is per project and
--- linters_by_ft is global.
function M.php_linters(bufnr)
  return resolve(bufnr) and { "phpstan" } or {}
end

--- Per-file analysis on save catches the file being edited. This catches what
--- that change broke elsewhere.
local function run_project(level)
  local ctx = resolve(0)
  if not ctx then
    return vim.notify(
      "phpstan: needs vendor/bin/phpstan and a phpstan.neon in the Laravel root",
      vim.log.levels.WARN
    )
  end

  local cmd = { ctx.bin }
  vim.list_extend(cmd, args(ctx))
  if level then vim.list_extend(cmd, { "--level", level }) end

  vim.notify("phpstan: analysing " .. vim.fn.fnamemodify(ctx.root, ":t") .. "…")
  -- clear = true so the agent markers stripped by clean_env() are really absent
  -- rather than merged back in from the parent environment.
  vim.system(cmd, { cwd = ctx.root, text = true, env = clean_env(), clear = true }, function(res)
    vim.schedule(function()
      local json = split_output(res.stdout or "")
      local ok, decoded = pcall(vim.json.decode, json or "")
      if not ok or type(decoded) ~= "table" then
        return vim.notify(
          "phpstan failed\n" .. vim.trim((res.stderr or "") .. (res.stdout or "")):sub(1, 500),
          vim.log.levels.ERROR
        )
      end

      local items = {}
      -- decoded.files is a JSON object keyed by path, except with no errors at
      -- all, where phpstan emits `"files": []`.
      for path, file in pairs(decoded.files or {}) do
        for _, m in ipairs(file.messages or {}) do
          items[#items + 1] = {
            filename = path,
            lnum = type(m.line) == "number" and m.line or 1,
            col = 1,
            text = m.message,
            type = "E",
          }
        end
      end
      -- Not file-scoped (config errors, unmatched ignores).
      for _, m in ipairs((decoded.errors or {})) do
        items[#items + 1] = { filename = ctx.config, lnum = 1, col = 1, text = tostring(m), type = "E" }
      end

      if #items == 0 then
        return vim.notify("phpstan: no errors")
      end
      table.sort(items, function(a, b)
        if a.filename ~= b.filename then return a.filename < b.filename end
        return a.lnum < b.lnum
      end)
      vim.fn.setqflist({}, "r", { title = "phpstan", items = items })
      vim.cmd("copen")
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("LaravelPhpstan", function(opts)
    run_project(opts.args ~= "" and opts.args or nil)
  end, {
    nargs = "?",
    desc = "Laravel: phpstan/larastan over the whole project into quickfix (optional level)",
  })
end

return M
