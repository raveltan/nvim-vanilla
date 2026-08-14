-- blink.cmp: the completion engine, replacing vim.lsp.completion.
--
-- Native completion could not carry this config's needs. It autotriggers only on
-- a server's own triggerCharacters -- no server claims a letter, so a name typed
-- after `(` or at the start of a statement reached nobody -- and on an incomplete
-- list it ranks by sortText alone, which tsserver stamps `"11"` on every item, so
-- the order was redrawn arbitrarily on each keystroke. blink triggers on keyword
-- characters and does its own fuzzy ranking, which is both problems.
--
-- Speed: the matcher is the Rust one (`prefer_rust` falls back to Lua only if the
-- prebuilt library is missing), the LSP list is capped after ranking, and the
-- documentation popup is delayed so it never costs anything while typing.
local M = {}

-- Angular inline-template completion -- component tags, @Input/@Output, enum
-- values (lua/gaf/angular/inputs_source.lua). GAF-only: the source indexes every
-- `selector:` under the search root, wasted work in a non-Angular project.
local function sources()
  local s = {
    default = { "lsp", "path", "snips", "buffer" },
    -- lua only: the provider require()s lazydev, which core/plugins.lua packadds
    -- on FileType lua, so listing it in `default` would fault in every other
    -- buffer. lua_ls cannot see plugin modules or `vim.uv`; lazydev can, so its
    -- items outrank the server's for require() paths and vim API names.
    -- sql/mysql/plsql: blink does not consult 'omnifunc', which is all
    -- dadbod-completion registers, so its table/column items need the source
    -- listed here. core/plugins.lua packadds it on those filetypes.
    per_filetype = {
      lua = { "lazydev", "lsp", "path", "snips", "buffer" },
      mysql = { "dadbod", "snips", "buffer" },
      plsql = { "dadbod", "snips", "buffer" },
      sql = { "dadbod", "snips", "buffer" },
    },
    providers = {
      dadbod = { name = "Dadbod", module = "vim_dadbod_completion.blink" },
      lsp = { max_items = 50 },
      snips = { name = "Snippets", module = "core.snippet_source", score_offset = -3 },
      lazydev = { name = "LazyDev", module = "lazydev.integrations.blink", score_offset = 100 },
    },
  }
  if vim.g.gaf then
    s.per_filetype.typescript = { "angular", "lsp", "path", "snips", "buffer" }
    s.providers.angular = {
      name = "Angular",
      module = "gaf.angular.inputs_source",
      -- Float component inputs above generic LSP/buffer noise when the cursor is
      -- actually inside a component tag.
      score_offset = 5,
    }
  end
  return s
end

function M.setup()
  require("blink.cmp").setup({
    -- <CR> accepts, <C-n>/<C-p> move. Tab is left alone: core/snippets.lua owns
    -- it for vim.snippet placeholder jumps.
    keymap = { preset = "enter" },
    appearance = { nerd_font_variant = "mono" },
    snippets = { preset = "default" }, -- vim.snippet, the same engine Tab jumps
    completion = {
      accept = { resolve_timeout_ms = 500 },
      documentation = {
        auto_show = true,
        auto_show_delay_ms = 200,
        window = { border = "rounded" },
      },
      -- virt_text_pos="inline" extmarks can survive a buffer/redraw race and
      -- leave "typed" text that cannot be deleted and is not undoable.
      ghost_text = { enabled = false },
      list = { selection = { preselect = true, auto_insert = false } },
      menu = {
        border = "rounded",
        scrollbar = false,
        draw = {
          treesitter = { "lsp" },
          columns = {
            { "kind_icon", "label", "label_description", gap = 1 },
            { "kind", gap = 1 },
          },
        },
      },
    },
    signature = { enabled = true, window = { border = "rounded" } },
    sources = sources(),
    fuzzy = { implementation = "prefer_rust" },
  })
end

return M
