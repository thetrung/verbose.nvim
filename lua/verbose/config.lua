local M = {}

M.defaults = {
  -- Path to `verbose` compiler binary; nil = auto-resolve (managed install -> PATH)
  verbose_bin = nil,
  -- GitHub release repo & tag ("latest" or e.g. "v0.6.0") for :VerboseInstall
  release_repo = "thetrung/verbose-lang",
  release_tag = "latest",
  -- Automatically download latest `verbose` binary if missing on PATH
  auto_install_compiler = false,
  -- Extra Include search directories (relative to workspace root or absolute)
  include_paths = { ".", "src", "std", ".vpkg/include" },
  -- Enable built-in in-process LSP (completion, gd, hover, outline, signatureHelp)
  lsp = {
    enabled = true,
  },
  -- Run `verbose --emit-only` on open/save for real compiler diagnostics
  diagnostics = {
    enabled = true,
    on_save = true,
    on_open = true,
  },
  -- Register & start bundled Tree-sitter grammar automatically
  treesitter = {
    enabled = true,
    auto_build = true,
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
