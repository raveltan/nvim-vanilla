-- bin/run-tests setup/shutdown for fl-gaf's Docker test infrastructure. The
-- cached worker IDs under .cache/gaf_session_* are what lets per-session Docker
-- stacks tear down individually.

local M = {}

-- Resolved from the buffer, not cwd: these are bound on php buffers, so nvim
-- started anywhere but the repo root would otherwise report "no bin/run-tests"
-- with an fl-gaf file open.
local function find_root()
  return require("gaf.paths").find_root("bin/run-tests", vim.api.nvim_buf_get_name(0))
end

local function run(dir, args, env, on_exit)
  vim.system({ dir .. "/bin/run-tests", unpack(args) }, { cwd = dir, env = env, text = true },
    function(res) vim.schedule(function() on_exit(res.code) end) end)
end

function M.setup_infra()
  local dir = find_root()
  if not dir then
    vim.notify("No bin/run-tests found", vim.log.levels.WARN)
    return
  end
  vim.notify("Setting up test infrastructure...")
  run(dir, { "setup" }, nil, function(code)
    if code == 0 then
      vim.notify("Test infrastructure ready")
    else
      vim.notify("Test setup failed (exit " .. code .. ")", vim.log.levels.ERROR)
    end
  end)
end

function M.shutdown_infra()
  local dir = find_root()
  if not dir then
    vim.notify("No bin/run-tests found", vim.log.levels.WARN)
    return
  end

  local worker_ids = {}
  local cache = dir .. "/.cache"
  for name in vim.fs.dir(cache) do
    if name:match("^gaf_session_") then
      -- pcall: a stale or unreadable session file throws E484, which would abort
      -- the teardown mid-loop.
      local ok, lines = pcall(vim.fn.readfile, cache .. "/" .. name)
      local id = ok and vim.trim(lines[1] or "") or ""
      if id ~= "" then worker_ids[#worker_ids + 1] = id end
    end
  end

  if #worker_ids == 0 then
    vim.notify("Tearing down test infrastructure...")
    run(dir, { "shutdown" }, nil, function(code)
      if code == 0 then
        vim.notify("Test infrastructure torn down")
      else
        vim.notify("Test shutdown failed (exit " .. code .. ")", vim.log.levels.ERROR)
      end
    end)
    return
  end

  vim.notify("Tearing down " .. #worker_ids .. " test session(s)...")
  local remaining, failed = #worker_ids, {}
  for _, wid in ipairs(worker_ids) do
    run(dir, { "shutdown" }, { GAF_TEST_WORKER_ID = wid }, function(code)
      if code ~= 0 then failed[#failed + 1] = wid end
      remaining = remaining - 1
      if remaining > 0 then return end
      if #failed == 0 then
        vim.notify("All test sessions torn down")
      else
        vim.notify("Shutdown failed for: " .. table.concat(failed, ", "), vim.log.levels.ERROR)
      end
    end)
  end
end

-- scripts/neotest-run-tests.sh reads GAF_DEBUG and passes --debug to
-- bin/run-tests, which enables xdebug in the test container against a host
-- listener on :9003.
function M.toggle_debug_flag()
  vim.env.GAF_DEBUG = vim.env.GAF_DEBUG ~= "1" and "1" or nil
  vim.notify(vim.env.GAF_DEBUG and "GAF_DEBUG=1 (next test run passes --debug)" or "GAF_DEBUG cleared")
end

return M
