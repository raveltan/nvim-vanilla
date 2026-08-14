-- Navigate and complete Angular components with treesitter + ripgrep. No LSP.
--
-- Tuned for INLINE-template Angular (`@Component({ template: `...` })`): selector
-- definitions and their usages live in `.ts` files, and the `angular` treesitter
-- parser auto-injects into the template backtick string (see core/plugins.lua),
-- which lets us read tag/attribute names under the cursor precisely. Projects
-- with external `.component.html` templates get the .ts-side navigation
-- (selectors, @Input/@Output, routes) but not the in-template reads, which need
-- the injected tree.
--
-- The module is not GAF-specific -- it works in any Angular project -- but it is
-- gated with the rest of the GAF tooling, because a repo-wide selector index only
-- pays for itself in the webapp.
--
--   search.lua      rg + jump/picker plumbing, the search root
--   patterns.lua    the rg patterns every lookup chases
--   ts.lua          treesitter helpers (traversal, decorators, edit ranges)
--   context.lua     what the cursor is on inside a template
--   nav.lua         gd, parents, component-by-name
--   routes.lua      URL string -> routing module
--   component.lua   reading a component file (inputs, facts, import specs, enums)
--   completion.lua  the data behind the completion source
--   edits.lua       the text edits an accepted completion needs
--   *_index.lua     the two repo-wide indexes tag completion reads
--   inputs_source.lua  the blink.cmp source itself (see core/completion.lua)
--
-- Required inside the callbacks rather than up here: setup() runs during
-- startup, and nothing in the module tree is needed until a `gd`, a `.ts` write
-- or the completion source pulls it in (1.3ms measured).
local M = {}

-- Rebuild the index for the current file's root, for when a rename/branch switch
-- moved more than the write-time patching can follow. The NgModule index is only
-- dropped, not rebuilt: nothing needs it until an NgModule-declared tag is
-- completed, and that lookup builds it.
function M.reindex()
  local search = require("gaf.angular.search")
  local selector_index = require("gaf.angular.selector_index")
  local root = search.buf_root(0)
  selector_index.invalidate(root)
  require("gaf.angular.module_index").invalidate(root)
  selector_index.get(root, search.rg_run, function(idx)
    local n = 0
    for _ in pairs(idx) do n = n + 1 end
    search.notify(n .. " selectors indexed under " .. root)
  end)
end

-- Buffer-local `gd` shadows the global fzf-lua `gd` on TS buffers, and falls back
-- to it when the cursor isn't on an Angular target.
--   gd         -> definition under cursor: tag (component), attr (@Input/@Output),
--                 class (scss), a symbol in a binding expression (its TS def), or
--                 a template-local (@if `as`, @for var, @let, #ref) binding site
--   <leader>cp -> parent components (callers that use this selector, "up")
--   <leader>cG -> prompt for a component name (class or selector) -> its definition
--   <leader>cR -> URL string under cursor -> routing module that handles it
function M.setup()
  local group = vim.api.nvim_create_augroup("angular_nav", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "typescript",
    callback = function(ev)
      local function bmap(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = ev.buf, desc = desc })
      end
      bmap("gd", function()
        if not require("gaf.angular.nav").goto_definition() then
          require("fzf-lua").lsp_definitions()
        end
      end, "Go to definition (Angular template-aware)")
      bmap("<leader>cp", function() require("gaf.angular.nav").goto_parents() end,
        "Angular: go to parent components")
      bmap("<leader>cG", function() require("gaf.angular.nav").goto_component_prompt() end,
        "Angular: go to component by name")
      bmap("<leader>cR", function() require("gaf.angular.routes").goto_route() end,
        "Angular: go to route module for URL")
    end,
  })
  -- Keep the already-built indexes current. update_file is a no-op on a root
  -- nobody has indexed, so a write never triggers the repo-wide rg.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.ts",
    callback = function(ev)
      local file = vim.api.nvim_buf_get_name(ev.buf)
      local root = require("gaf.angular.search").search_root(file)
      require("gaf.angular.selector_index").update_file(root, file)
      require("gaf.angular.module_index").update_file(root, file)
    end,
  })
  vim.api.nvim_create_user_command("AngularReindex", M.reindex,
    { desc = "Angular: rebuild the component selector index" })
end

return M
