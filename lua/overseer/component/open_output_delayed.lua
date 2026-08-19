-- Same idea as overseer's builtin open_output, but the float open is deferred
-- one event-loop tick.
--
-- task:start() (reached synchronously from the fzf-lua template-picker
-- callback bound to <leader>or) can still be running inside a floating
-- window / non-normal mode at that exact instant. overseer's jobstart
-- strategy guards real terminal attachment on both being clear
-- (JobstartStrategy.can_create_terminal in strategy/jobstart.lua) and defers
-- attachment via queue_terminal_creation otherwise. Opening the float
-- synchronously in on_start races that guard: the float shows the
-- not-yet-attached scratch buffer, which then never receives output, because
-- the float itself is a floating window, so the deferred attach can't run
-- until the float is closed. Scheduling this call lets the deferred attach
-- resolve first, so the float opens against an already-live buffer.
return {
  desc = "Open task output in a float, after yielding once for the terminal to attach",
  params = {
    direction = {
      desc = "Where to open the task output",
      type = "enum",
      choices = { "dock", "float", "tab", "vertical", "horizontal" },
      default = "float",
    },
    focus = {
      desc = "Focus the output window when it is opened",
      type = "boolean",
      default = true,
    },
  },
  constructor = function(params)
    return {
      on_start = function(_, task)
        vim.schedule(function()
          if task:is_disposed() then return end
          local winid = vim.api.nvim_get_current_win()
          task:open_output(params.direction)
          if not params.focus then
            vim.api.nvim_set_current_win(winid)
          end
        end)
      end,
    }
  end,
}
