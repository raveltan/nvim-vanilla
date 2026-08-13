-- `git log -L` / `--follow` history for the current line, a visual range, or the
-- whole file, picked with fzf-lua and opened read-only through fugitive's :Gedit.
-- Nothing is ever checked out.
--
-- The preview is fzf's own `git show` subprocess rather than an async Lua
-- pipeline, because fzf caches it per row and kills it on scroll. The previous
-- snacks version hand-rolled that with a cache table and a generation counter.

local M = {}

-- git runs with cwd set to the file's own directory and every pathspec is the
-- bare basename, so a file outside nvim's cwd (another repo, a worktree) still
-- resolves where a cwd-relative path would find nothing.
local function target()
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("No file", vim.log.levels.WARN)
    return nil
  end
  return {
    rel = vim.fn.fnamemodify(file, ":."),
    dir = vim.fn.fnamemodify(file, ":h"),
    name = vim.fn.fnamemodify(file, ":t"),
  }
end

local function pick_commits(t, log_args, title, empty_msg)
  local cmd = { "git", "log", "-n", "200", "--no-patch", "--pretty=format:%h  %ar  %an  %s" }
  vim.list_extend(cmd, log_args)

  -- `git log -L` traces history with no early exit, and a synchronous systemlist
  -- froze nvim for seconds on old files. -n 200 bounds the worst case.
  vim.system(cmd, { text = true, cwd = t.dir }, vim.schedule_wrap(function(res)
    local entries = vim.split(res.stdout or "", "\n", { trimempty = true })
    if res.code ~= 0 or #entries == 0 then
      vim.notify(empty_msg, vim.log.levels.WARN)
      return
    end

    local function sha_of(selected)
      return selected[1] and selected[1]:match("^(%x+)")
    end

    require("fzf-lua").fzf_exec(entries, {
      prompt = "Commits> ",
      winopts = {
        title = " " .. title .. " ",
        preview = { layout = "vertical", vertical = "down:65%" },
      },
      fzf_opts = {
        ["--preview"] = ("git -C %s show --color=always --format= --stat -p {1} -- %s")
          :format(vim.fn.shellescape(t.dir), vim.fn.shellescape(t.name)),
      },
      actions = {
        ["default"] = function(selected)
          local sha = sha_of(selected)
          if sha then vim.cmd("Gedit " .. sha) end
        end,
        ["ctrl-y"] = function(selected)
          local sha = sha_of(selected)
          if sha then
            vim.fn.setreg("+", sha)
            vim.notify("Copied " .. sha)
          end
        end,
      },
    })
  end))
end

function M.pick(s, e)
  local t = target()
  if not t then return end
  if not (s and e) then
    s = vim.fn.line(".")
    e = s
  end
  pick_commits(t,
    { ("-L%d,%d:%s"):format(s, e, t.name) },
    ("Line history %d-%d : %s"):format(s, e, t.rel),
    ("No history for lines %d-%d"):format(s, e))
end

function M.file()
  local t = target()
  if not t then return end
  pick_commits(t,
    { "--follow", "--", t.name },
    "File history : " .. t.rel,
    "No history for " .. t.rel)
end

return M
