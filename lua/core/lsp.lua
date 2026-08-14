-- LSP through the 0.12 native API. No mason, no `require("lspconfig")`.
--
-- nvim-lspconfig is on 'runtimepath' as data only. vim.lsp.enable("x") reads
-- `lsp/x.lua` off the rtp, and core/plugins.lua marks the plugin `data = true`
-- so its plugin/ script is never sourced and none of its Lua ever runs. That
-- buys correct cmd/filetypes/root_markers, including the fiddly ones like
-- eslint.
--
-- Server binaries come from brew/npm/cargo. Every server below is
-- executable-guarded, so a missing binary is a server that never starts.

-- name -> the executable that must exist for it to be enabled.
local SERVERS = {
  lua_ls = "lua-language-server",
  vtsls = "vtsls",
  eslint = "vscode-eslint-language-server",
  basedpyright = "basedpyright-langserver",
  ruff = "ruff",
  jsonls = "vscode-json-language-server",
  yamlls = "yaml-language-server",
  html = "vscode-html-language-server",
  cssls = "vscode-css-language-server",
  tailwindcss = "tailwindcss-language-server",
  typos_lsp = "typos-lsp",
  emmet_language_server = "emmet-language-server",
  intelephense = "intelephense",
  rust_analyzer = "rust-analyzer",
  sourcekit = "sourcekit-lsp",
}

-- Each override below merges on top of nvim-lspconfig's lsp/<server>.lua.
local function configure()
  vim.lsp.config("lua_ls", {
    settings = {
      Lua = {
        workspace = { checkThirdParty = false },
        telemetry = { enable = false },
      },
    },
  })

  vim.lsp.config("vtsls", {
    settings = {
      typescript = {
        tsserver = { maxTsServerMemory = 8192 },
        preferences = {
          importModuleSpecifier = "relative",
          includePackageJsonAutoImports = "auto",
        },
        updateImportsOnFileMove = { enabled = "always" },
      },
      javascript = {
        updateImportsOnFileMove = { enabled = "always" },
      },
    },
  })

  vim.lsp.config("eslint", {
    settings = {
      run = "onSave",
      packageManager = "yarn",
    },
    flags = {
      allow_incremental_sync = false,
      debounce_text_changes = 1000,
    },
  })

  vim.lsp.config("basedpyright", {
    settings = {
      basedpyright = {
        analysis = {
          autoSearchPaths = true,
          useLibraryCodeForTypes = true,
          autoImportCompletions = true,
        },
      },
    },
  })

  -- Ruff keeps lint, format and import sorting, but hover is basedpyright's.
  vim.lsp.config("ruff", {
    on_attach = function(client, _)
      client.server_capabilities.hoverProvider = false
    end,
  })

  -- Requiring SchemaStore inside before_init keeps its large catalog table out
  -- of memory until a json or yaml file is actually opened.
  vim.lsp.config("jsonls", {
    before_init = function(_, config)
      config.settings = vim.tbl_deep_extend("force", config.settings or {}, {
        json = { schemas = require("schemastore").json.schemas(), validate = { enable = true } },
      })
    end,
  })

  vim.lsp.config("yamlls", {
    before_init = function(_, config)
      config.settings = vim.tbl_deep_extend("force", config.settings or {}, {
        yaml = {
          -- SchemaStore.nvim is the catalog, so the built-in store stays off.
          schemaStore = { enable = false, url = "" },
          schemas = require("schemastore").yaml.schemas(),
        },
      })
    end,
  })

  vim.lsp.config("tailwindcss", {
    filetypes = { "html", "css", "scss", "javascript", "typescript", "javascriptreact", "typescriptreact", "blade" },
    settings = {
      tailwindCSS = {
        experimental = { classRegex = { { "@apply\\s+([^;]*)", "" } } },
      },
    },
  })

  -- autoClosingTags stays off because nvim-ts-autotag already inserts the close
  -- tag, and both together produce a duplicate `</tag>`.
  vim.lsp.config("html", {
    filetypes = { "html", "blade" },
    init_options = {
      provideFormatter = false, -- conform owns html formatting
      configurationSection = { "html", "css", "javascript" },
      embeddedLanguages = { css = true, javascript = true },
    },
    settings = { html = { autoClosingTags = false } },
  })

  vim.lsp.config("cssls", { filetypes = { "css", "scss", "less" } })

  -- Emmet abbreviations arrive as ordinary completion items, expanded on accept.
  vim.lsp.config("emmet_language_server", {
    filetypes = {
      "html", "blade", "css", "scss", "sass", "less",
      "javascriptreact", "typescriptreact", "vue", "svelte", "htmldjango",
    },
    init_options = { showExpandedAbbreviation = "always" },
  })

  vim.lsp.config("typos_lsp", {
    init_options = { diagnosticSeverity = "Hint" },
  })

  -- The premium licence is picked up on its own: intelephense reads
  -- {globalStoragePath}/intelephense/licence.txt, and globalStoragePath defaults
  -- to $HOME, so ~/intelephense/licence.txt needs no init_options. Blade is left
  -- out of filetypes because the parser is PHP-only and every @directive is a
  -- syntax error.
  vim.lsp.config("intelephense", {
    filetypes = { "php" },
    -- Nested tables are priority order, so .git wins and a monorepo roots once
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
        files = {
          -- Default 1MB skips generated PHP in the monolith, and a skipped file
          -- is an undefined symbol everywhere it is used.
          maxSize = 5000000,
          -- This replaces the default list rather than extending it, so the
          -- defaults are respelled. The one addition is blade: *.blade.php
          -- matches the *.php association, so a views/ tree would be indexed as
          -- PHP that fails to parse at the first @directive.
          exclude = {
            "**/.git/**", "**/.svn/**", "**/.hg/**", "**/CVS/**", "**/.DS_Store/**",
            "**/node_modules/**", "**/bower_components/**", "**/.history/**",
            "**/vendor/**/{Tests,tests}/**", "**/vendor/**/vendor/**",
            "**/*.blade.php",
          },
        },
        -- No `inlayHint` block: the settings exist in intelephense's schema but
        -- the npm server (1.14.4) answers textDocument/inlayHint with "Unhandled
        -- method" and never advertises the capability, so the hints are the
        -- VSCode extension's own. on_attach's supports_method guard skips PHP.
      },
    },
  })

  -- sourcekit needs dynamically-registered file watching to see cross-file
  -- changes. Its default filetypes also claim c/cpp/objc, hence the narrowing.
  vim.lsp.config("sourcekit", {
    capabilities = {
      workspace = { didChangeWatchedFiles = { dynamicRegistration = true } },
    },
    filetypes = { "swift" },
  })
end

-- Silent by design. The underline is the whole in-buffer signal and the message
-- text appears only when <leader>cd asks for it.
local function diagnostics()
  vim.diagnostic.config({
    virtual_text = false,
    virtual_lines = false,
    signs = false,
    underline = { severity = { min = vim.diagnostic.severity.HINT } },
    update_in_insert = false,
    float = { border = "rounded", source = true },
    severity_sort = true,
  })

  -- Underdouble is the heaviest style extended SGR offers, two stacked rules
  -- carried by Ghostty and the tmux Smulx/Setulc overrides. Severity still reads
  -- through the theme's underline colour, and a terminal without extended SGR
  -- falls back to a plain single underline.
  local function style_underlines()
    for _, level in ipairs({ "Error", "Warn", "Info", "Hint", "Ok" }) do
      local name = "DiagnosticUnderline" .. level
      local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
      -- Keep the theme's underline colour (sp), replace only the style bits.
      hl.undercurl, hl.underline = nil, nil
      hl.underdouble, hl.underdotted, hl.underdashed = nil, nil, nil
      -- cterm carries its own copy of the style bits.
      hl.cterm = { underdouble = true }
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", hl, { underdouble = true }))
    end
  end
  style_underlines()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("diagnostic_underline_styles", { clear = true }),
    callback = style_underlines,
  })
end

local function on_attach(ev)
  local client = vim.lsp.get_client_by_id(ev.data.client_id)
  if not client then return end

  -- On by default, per-buffer toggle on <leader>uh.
  if client:supports_method("textDocument/inlayHint") then
    vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
  end
end

-- The TSTools* commands typescript-tools used to provide. vtsls exposes them as
-- code-action kinds plus one workspace command.
local function ts_keymaps()
  local function ts_action(kind)
    return function()
      vim.lsp.buf.code_action({ apply = true, context = { only = { kind }, diagnostics = {} } })
    end
  end
  local function goto_source_definition()
    local client = vim.lsp.get_clients({ bufnr = 0, name = "vtsls" })[1]
    if not client then return end
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    client:request("workspace/executeCommand", {
      command = "typescript.goToSourceDefinition",
      arguments = { params.textDocument.uri, params.position },
    }, function(err, locations)
      if err or not locations or vim.tbl_isempty(locations) then
        vim.notify("No source definition found", vim.log.levels.WARN)
        return
      end
      vim.lsp.util.show_document(locations[1], client.offset_encoding)
    end, 0)
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("ts_source_actions", { clear = true }),
    pattern = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
    callback = function(ev)
      local function bmap(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = ev.buf, silent = true, desc = desc })
      end
      bmap("<leader>co", ts_action("source.organizeImports"), "TS: organize imports")
      bmap("<leader>cM", ts_action("source.addMissingImports.ts"), "TS: add missing imports")
      bmap("<leader>cU", ts_action("source.removeUnusedImports"), "TS: remove unused imports")
      bmap("<leader>cx", ts_action("source.removeUnused.ts"), "TS: remove unused")
      bmap("<leader>cF", ts_action("source.fixAll.ts"), "TS: fix all")
      bmap("<leader>cD", goto_source_definition, "TS: go to source definition")
    end,
  })
end

diagnostics()
configure()
ts_keymaps()

local enabled = {}
for name, bin in pairs(SERVERS) do
  if vim.fn.executable(bin) == 1 then
    enabled[#enabled + 1] = name
  end
end
table.sort(enabled)

if vim.g.gaf then
  -- tailwindcss never starts in the monolith and its scan is expensive.
  enabled = vim.tbl_filter(function(s) return s ~= "tailwindcss" end, enabled)
  require("gaf.lsp").apply()
end

vim.lsp.enable(enabled)

vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("lsp_attach", { clear = true }),
  callback = on_attach,
})

vim.api.nvim_create_user_command("LspServers", function()
  local lines = {}
  for name, bin in vim.spairs(SERVERS) do
    lines[#lines + 1] = ("%-24s %-34s %s"):format(name, bin,
      vim.fn.executable(bin) == 1 and "installed" or "MISSING")
  end
  vim.notify(table.concat(lines, "\n"))
end, { desc = "Which language servers are on PATH" })
