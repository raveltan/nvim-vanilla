local M = {}

-- enter=true so the float takes focus and scrolls without a second keypress.
local function open_float(lines, title, wrap)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "git"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 1
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 1, math.floor(vim.o.columns * 0.85))
  local height = math.min(math.max(#lines, 1), math.floor(vim.o.lines * 0.7))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
  })
  vim.wo[win].wrap = wrap or false
  vim.wo[win].conceallevel = 0
  for _, k in ipairs({ "q", "<esc>" }) do
    vim.keymap.set("n", k, "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  end
end

local function strip_leading_blanks(t)
  while t[1] == "" do
    table.remove(t, 1)
  end
  if t[#t] == "" then
    t[#t] = nil
  end
  return t
end

function M.blame(mode)
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("No file", vim.log.levels.WARN)
    return
  end
  local dir = vim.fn.fnamemodify(file, ":h")
  local lnum = vim.fn.line(".")
  local sys = { text = true, cwd = dir }

  vim.system(
    { "git", "blame", "-L", lnum .. "," .. lnum, "--line-porcelain", "--", file },
    sys,
    vim.schedule_wrap(function(res)
      if res.code ~= 0 then
        vim.notify("git blame failed:\n" .. (res.stderr or ""), vim.log.levels.ERROR)
        return
      end
      local out = vim.split(res.stdout or "", "\n")
      local sha = out[1] and out[1]:match("^(%x+)")
      if not sha then
        vim.notify("Could not parse blame", vim.log.levels.WARN)
        return
      end
      if sha:match("^0+$") then
        open_float({ "Not committed yet" }, " blame ", true)
        return
      end

      local author, atime
      for _, l in ipairs(out) do
        author = l:match("^author (.+)$") or author
        atime = l:match("^author%-time (%d+)$") or atime
      end
      local title = string.format(
        "%s %s (%s)",
        sha:sub(1, 8),
        author or "",
        atime and vim.fn.strftime("%Y-%m-%d %H:%M", tonumber(atime)) or ""
      )

      if mode == "message" then
        vim.system({ "git", "show", "-s", "--format=%B", sha }, sys, vim.schedule_wrap(function(m)
          local body = strip_leading_blanks(vim.split(m.stdout or "", "\n"))
          local lines = { title, "" }
          vim.list_extend(lines, body)
          open_float(lines, " blame: message ", true)
        end))
      else
        vim.system(
          { "git", "show", "--format=", "-p", sha, "--", file },
          sys,
          vim.schedule_wrap(function(d)
            local diff = strip_leading_blanks(vim.split(d.stdout or "", "\n"))
            local lines = { title }
            if #diff == 0 then
              table.insert(lines, "(no diff for this file in this commit)")
            else
              vim.list_extend(lines, diff)
            end
            open_float(lines, " blame: diff ", false)
          end)
        )
      end
    end)
  )
end

return M
