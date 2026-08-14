-- GAF server overrides, layered on top of core/lsp.lua's generic config.

local M = {}

local API_ROOT = vim.fn.expand("~/freelancer-dev/api")

-- The api repo is a multi-package monorepo. Each top-level service dir is its
-- own setuptools project and the importable package sits one level inside it,
-- often under a different name (rest/ -> api, users_midlayer/ -> users_mid), so
-- the outer dirs are the import roots pyright needs. The repo root itself is
-- included so pyright discovers gaf_thrift-stubs/ as PEP-561 stubs for the
-- gaf_thrift pip package, a gitignored dir regenerated from the thrift repo with
-- run.sh build_thrift_definitions.
local function basedpyright_extra_paths()
  local paths = { API_ROOT }
  for _, s in ipairs({
    "rest", "restutils", "libgafthrift", "pii_store",
    "users_midlayer", "users_dao",
    "messages_midlayer", "messages_dao",
    "projects_midlayer", "projects_dao",
  }) do
    paths[#paths + 1] = API_ROOT .. "/" .. s
  end
  return paths
end

-- py3.11 venv (pyenv, outside the repo) holding the api repo's third-party deps
-- from the Nexus mirror, so Flask/boto3/gaf_thrift resolve. Created with
-- `pyenv virtualenv 3.11.14 api311`.
local PYTHON = vim.fn.expand("~/.pyenv/versions/api311/bin/python")

local PY_MARKERS = { "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile", "pyrightconfig.json" }

function M.apply()
  -- fl-gaf's eslint local-rules/validate-freelancer-imports bans relative
  -- @freelancer imports, but self-imports inside a @freelancer/ui package must
  -- stay relative. project-relative satisfies both.
  vim.lsp.config("vtsls", {
    settings = {
      typescript = { preferences = { importModuleSpecifier = "project-relative" } },
    },
  })

  -- Merged over core/lsp.lua's basedpyright block, which already sets
  -- autoSearchPaths / useLibraryCodeForTypes / autoImportCompletions.
  local analysis = {
    extraPaths = basedpyright_extra_paths(),
    -- basedpyright defaults to "recommended", its strictest mode, which floods
    -- legacy api-repo code. mypy-in-docker is the real type gate.
    typeCheckingMode = "standard",
    -- gaf_thrift-stubs use the legacy mypy stub convention (enum members
    -- annotated `X: int = ...`), which the current typing spec, and so pyright,
    -- reads as plain int attributes rather than enum members, false-erroring
    -- every thrift exception/enum call site. The thrift Iface multiple
    -- inheritance pattern trips override checks, and stub-only packages (six,
    -- grpc, gaf_thrift) warn about missing source.
    diagnosticSeverityOverrides = {
      reportArgumentType = "none",
      reportIncompatibleMethodOverride = "none",
      reportMissingModuleSource = "none",
      -- Warning, not error: pyright infers unannotated legacy helpers' return
      -- types as unions, then flags attrs of the wrong union member. Real typos
      -- still show as yellow.
      reportAttributeAccessIssue = "warning",
      reportOptionalMemberAccess = "warning",
      reportOptionalOperand = "warning",
      reportOptionalIterable = "warning",
      reportOptionalSubscript = "warning",
    },
  }

  local config = {
    settings = { basedpyright = { analysis = analysis } },
    -- Every api/ service dir has its own setup.py, which outranks .git in the
    -- default flat marker list and would root one server per service, breaking
    -- cross-service imports and the extraPaths above.
    --
    -- A resolver rather than nested `root_markers`: vim.lsp.config merges with
    -- tbl_deep_extend("force"), which merges lists BY INDEX, so two tiers laid
    -- over nvim-lspconfig's flat 7-entry list leave five stray string tiers
    -- behind, harmless but unreachable. This sidesteps the merge entirely.
    root_dir = function(bufnr, on_dir)
      local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
      if dir == "" then return end
      local root = vim.fs.root(dir, ".git") or vim.fs.root(dir, PY_MARKERS)
      if root then on_dir(root) end
    end,
  }
  -- Only wired up when the venv exists, so a fresh machine degrades to
  -- intra-repo + stub completion instead of failing to start.
  if vim.fn.executable(PYTHON) == 1 then
    config.settings.python = { pythonPath = PYTHON }
  end
  vim.lsp.config("basedpyright", config)

  -- The monolith's PHP server. Nothing outside GAF configures intelephense, so
  -- this merges straight onto nvim-lspconfig's lsp/intelephense.lua and is the
  -- only place its settings live.
  --
  -- The premium licence is picked up on its own: intelephense reads
  -- {globalStoragePath}/intelephense/licence.txt, and globalStoragePath defaults
  -- to $HOME, so ~/intelephense/licence.txt needs no init_options. Blade is left
  -- out of filetypes because the parser is PHP-only and every @directive is a
  -- syntax error.
  vim.lsp.config("intelephense", {
    filetypes = { "php" },
    -- Nested tables are priority order, so .git wins and the monolith roots once
    -- at the top rather than at whichever nested composer.json is closest.
    root_markers = { { ".git" }, { "composer.json" } },
    init_options = {
      -- The index lives under storagePath, which defaults to os.tmpdir(). macOS
      -- prunes /var/folders, so a monolith-sized workspace re-indexes from
      -- scratch every time it is cleared. globalStoragePath is deliberately not
      -- set: it defaults to $HOME, which is where the licence file lives.
      storagePath = vim.fn.stdpath("cache") .. "/intelephense",
    },
    settings = {
      intelephense = {
        -- intelephense assumes 8.5.0 and has no idea what composer.json
        -- requires, so it happily suggests syntax and stdlib the deployed 8.1
        -- runtime rejects.
        environment = { phpVersion = "8.1.32" },
        -- conform runs fl-gaf's own php-cs-fixer build with the per-tree
        -- ruleset, so the server's formatter is dead weight that would fight it
        -- on lsp_format fallback.
        format = { enable = false },
        files = {
          -- Default 1MB skips generated PHP in the monolith, and a skipped file
          -- is an undefined symbol everywhere it is used.
          maxSize = 5000000,
          -- This replaces the default list rather than extending it, so the
          -- defaults are respelled. Two additions:
          --   *.blade.php matches the *.php association, so views/ would be
          --   indexed as PHP that fails to parse at the first @directive.
          --   webapp/ is 22GB of Angular holding zero PHP files, and the scan
          --   still walks every directory it is not told to skip.
          exclude = {
            "**/.git/**", "**/.svn/**", "**/.hg/**", "**/CVS/**", "**/.DS_Store/**",
            "**/node_modules/**", "**/bower_components/**", "**/.history/**",
            "**/vendor/**/{Tests,tests}/**", "**/vendor/**/vendor/**",
            "**/*.blade.php",
            "**/webapp/**",
          },
        },
        -- No `inlayHint` block: the settings exist in intelephense's schema but
        -- the npm server (1.14.4) answers textDocument/inlayHint with "Unhandled
        -- method" and never advertises the capability, so the hints are the
        -- VSCode extension's own. on_attach's supports_method guard skips PHP.
      },
    },
  })
end

return M
