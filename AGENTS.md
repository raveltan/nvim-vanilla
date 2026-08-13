# Rules for this config

## Comments

Write a comment only when the code cannot be made clear on its own. If a comment
restates the line below it, delete the comment or rewrite the code.

A comment earns its place when it records one of:

- why a non-obvious choice was made over the obvious one
- a workaround for an upstream bug, named with its issue or version
- a measured number, with the measurement
- an ordering constraint or invariant that is easy to break later
- an API contract that is genuinely surprising

Banned in comments:

- em dashes. Use a full stop or a comma.
- semicolons. Split the sentence.
- filler openers such as "Note that", "Basically", "Simply", "In order to"
- restating a function name in prose
- section banners in a short file
- documenting a parameter or return value that the code already shows
- tutorial voice. The reader knows Vim and Lua.

Prefer one plain sentence. Two only when the reason genuinely needs them.

## Code

Keep it slim. Fewer lines beats clever lines. Delete anything unreachable rather
than guarding it.

Two-space indent. No stylua. There is no stylua config and running it reformats
the whole tree to tabs.

Do not set an option to its own default. Verify with
`nvim --clean --headless -c 'lua =vim.o.<name>' -c qa` before adding one.

Do not pass a plugin option that matches the plugin's default. Read the plugin
source to confirm.

## Verifying

Measure before claiming a speedup. `vim.uv.hrtime()` around the real call, or
`--startuptime`, and report the number.

After any change:

```sh
NVIM_APPNAME=nvim-vanilla nvim --headless -c 'lua vim.defer_fn(function() vim.cmd("qa!") end, 1500)'
GAF=1 NVIM_APPNAME=nvim-vanilla nvim --headless -c 'lua vim.defer_fn(function() vim.cmd("qa!") end, 1500)'
```

Both profiles must boot silently.
