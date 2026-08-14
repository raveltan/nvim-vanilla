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

  -- intelephense assumes phpVersion 8.5.0 and has no idea what composer.json
  -- requires, so on the monolith it happily suggests syntax and stdlib the
  -- deployed 8.1 runtime rejects. Rooting is already right in the generic config.
  vim.lsp.config("intelephense", {
    settings = { intelephense = { environment = { phpVersion = "8.1.32" } } },
  })
end

return M
