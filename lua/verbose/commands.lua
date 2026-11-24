local index = require("verbose.index")
local installer = require("verbose.installer")
local lsp = require("verbose.lsp")

local M = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(src), "..", ".."))
end

function M.build_parser(silent)
  local script = vim.fs.joinpath(plugin_root(), "scripts", "build_parser.sh")
  if vim.fn.filereadable(script) ~= 1 then
    vim.notify("[verbose.nvim] build_parser.sh not found at " .. script, vim.log.levels.ERROR)
    return false
  end
  local res = vim.system({ "bash", script }, { text = true }):wait()
  if res.code == 0 then
    if not silent then
      vim.notify("[verbose.nvim] Tree-sitter parser built successfully.", vim.log.levels.INFO)
    end
    return true
  else
    vim.notify("[verbose.nvim] Parser build failed: " .. (res.stderr or res.stdout or ""), vim.log.levels.ERROR)
    return false
  end
end

local function run_in_split(cmd)
  vim.cmd("botright 14split")
  vim.cmd("terminal " .. cmd)
end

function M.register()
  vim.api.nvim_create_user_command("VerboseInstall", function(opts)
    local tag = (opts.args ~= "" and opts.args) or nil
    installer.install({ tag = tag })
    M.build_parser(false)
  end, { nargs = "?", desc = "Download latest VerBose-Lang compiler and build Tree-sitter parser" })

  vim.api.nvim_create_user_command("VerboseBuildParser", function()
    M.build_parser(false)
  end, { desc = "Compile bundled tree-sitter-verbose parser" })

  vim.api.nvim_create_user_command("VerboseRun", function(opts)
    local bin = installer.resolve_bin()
    if not bin then
      vim.notify("[verbose.nvim] `verbose` compiler not found. Run :VerboseInstall", vim.log.levels.WARN)
      return
    end
    local file = vim.api.nvim_buf_get_name(0)
    local extra = opts.args ~= "" and (" " .. opts.args) or ""
    run_in_split(vim.fn.shellescape(bin) .. " " .. vim.fn.shellescape(file) .. extra)
  end, { nargs = "*", desc = "Compile and run the current VerBose file" })

  vim.api.nvim_create_user_command("VerboseTest", function(opts)
    local bin = installer.resolve_bin()
    if not bin then
      vim.notify("[verbose.nvim] `verbose` compiler not found. Run :VerboseInstall", vim.log.levels.WARN)
      return
    end
    local target = opts.args ~= "" and opts.args or vim.api.nvim_buf_get_name(0)
    run_in_split(vim.fn.shellescape(bin) .. " test " .. target)
  end, { nargs = "*", desc = "Run VerBose Test/Assert suite" })

  vim.api.nvim_create_user_command("VerboseCheck", function()
    lsp.run_diagnostics(0)
  end, { desc = "Run VerBose semantic type-checker diagnostics on current buffer" })

  vim.api.nvim_create_user_command("VerboseCacheInfo", function()
    local n, files = index.cache_stats()
    vim.notify(string.format("[verbose.nvim] Indexed %d cached file(s):\n%s", n, table.concat(files, "\n")), vim.log.levels.INFO)
  end, { desc = "Show cached VerBose Include-graph files" })

  vim.api.nvim_create_user_command("VerboseCacheClear", function()
    index.clear_cache()
    vim.notify("[verbose.nvim] Cleared Include symbol cache.", vim.log.levels.INFO)
  end, { desc = "Clear cached VerBose Include symbols" })
end

return M
