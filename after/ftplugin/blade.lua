-- Neovim ships no ftplugin for `blade`, only the filetype detection, so without
-- this commentstring is empty and `gcc` silently does nothing.
vim.bo.commentstring = "{{-- %s --}}"
