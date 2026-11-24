-- Buffer-local settings for VerBose-Lang (.vb)
vim.bo.commentstring = "' %s"
vim.bo.comments = ":'"
vim.bo.expandtab = true
vim.bo.shiftwidth = 2
vim.bo.tabstop = 2
vim.bo.softtabstop = 2
vim.bo.iskeyword = "@,48-57,_,192-255"

-- Fallback omnifunc if LSP is disabled
vim.bo.omnifunc = "v:lua.require'verbose.lsp'.omnifunc"
