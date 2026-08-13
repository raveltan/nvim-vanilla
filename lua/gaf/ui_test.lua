-- Playwright UI tests in the GAF webapp, run as overseer tasks. The task shape
-- lives here; the templates built from it are in
-- lua/overseer/template/user/ui_test.lua, which overseer finds on the
-- runtimepath.
local M = {}

local function webapp()
  return require("gaf.paths").webapp_root()
end

--- yarn_script is a package.json script name ("ui:main:watch"); extra_env carries
--- the variant's own switches, e.g. { DEVTOOLS = "true" }.
function M.build_task(yarn_script, extra_env)
  return function(params)
    local spec = params.spec
    if spec == nil or spec == "" then spec = vim.fn.expand("%:t") end
    return {
      cmd = { "yarn", yarn_script },
      cwd = webapp(),
      env = vim.tbl_extend("error", { SPECS = spec }, extra_env or {}),
    }
  end
end

M.params = {
  spec = {
    type = "string",
    name = "SPECS",
    desc = "Spec pattern (blank = current file)",
    default = "",
    optional = true,
  },
}

M.condition = {
  callback = function() return vim.g.gaf and webapp() ~= nil end,
}

return M
