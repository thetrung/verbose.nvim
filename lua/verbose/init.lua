local config = require("verbose.config")
local commands = require("verbose.commands")
local installer = require("verbose.installer")
local lsp = require("verbose.lsp")

local M = {
  _is_setup = false,
}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(src), "..", ".."))
end

local function ensure_treesitter(bufnr)
  if not config.options.treesitter.enabled then return end
  local parser_path = vim.fs.joinpath(plugin_root(), "parser", "verbose.so")
  if vim.fn.filereadable(parser_path) ~= 1 and config.options.treesitter.auto_build then
    commands.build_parser(true)
  end
  if vim.fn.filereadable(parser_path) == 1 then
    pcall(vim.treesitter.language.add, "verbose", { path = parser_path })
    pcall(vim.treesitter.start, bufnr, "verbose")
  end
end

function M.setup(opts)
  config.setup(opts)
  M._is_setup = true

  -- Register custom parser metadata if nvim-treesitter is installed
  local ok_parsers, parsers = pcall(require, "nvim-treesitter.parsers")
  if ok_parsers and type(parsers.get_parser_configs) == "function" then
    local cfg = parsers.get_parser_configs()
    cfg.verbose = {
      install_info = {
        url = vim.fs.joinpath(plugin_root(), "tree-sitter-verbose"),
        files = { "src/parser.c" },
      },
      filetype = "verbose",
    }
  end

  if config.options.auto_install_compiler and not installer.resolve_bin() then
    installer.install({ silent = false })
  end
end

function M.on_attach(bufnr)
  ensure_treesitter(bufnr)
  lsp.attach(bufnr)

  if config.options.diagnostics.enabled then
    if config.options.diagnostics.on_open then
      lsp.run_diagnostics(bufnr)
    end
    if config.options.diagnostics.on_save then
      vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = bufnr,
        callback = function()
          lsp.run_diagnostics(bufnr)
        end,
      })
    end
  end
end

return M
