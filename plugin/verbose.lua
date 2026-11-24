if vim.g.loaded_verbose_nvim then
  return
end
vim.g.loaded_verbose_nvim = true

require("verbose.commands").register()

-- Auto-setup with sensible defaults if user didn't call require("verbose").setup()
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("VerboseNvimAutoSetup", { clear = true }),
  pattern = "verbose",
  callback = function(ev)
    local verbose = require("verbose")
    if not verbose._is_setup then
      verbose.setup()
    end
    verbose.on_attach(ev.buf)
  end,
})
