-- One template per (variant × devtools) pair, so `<leader>or` lists all eight
-- without eight near-identical files. The module name matches the
-- `^overseer%.template%.user%.` pattern lua/core/plugins.lua disables outside
-- GAF, and the provider condition below rejects a non-webapp cwd.
local h = require("gaf.ui_test")

local VARIANTS = {
  { script = "ui:main", label = "" },
  { script = "ui:main:mobile", label = "mobile " },
  { script = "ui:main:watch", label = "watch " },
  { script = "ui:main:mobile:watch", label = "mobile watch " },
}

return {
  condition = h.condition,
  generator = function(_, cb)
    local out = {}
    for _, v in ipairs(VARIANTS) do
      for _, devtools in ipairs({ false, true }) do
        out[#out + 1] = {
          name = "ui test " .. v.label .. (devtools and "devtools " or "") .. "(current)",
          params = h.params,
          builder = h.build_task(v.script, devtools and { DEVTOOLS = "true" } or nil),
        }
      end
    end
    cb(out)
  end,
}
