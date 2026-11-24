-- Downloads and manages the latest VerBose-Lang compiler binary from GitHub Releases
local config = require("verbose.config")

local M = {}

local function is_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

function M.platform_asset()
  local uname = vim.uv.os_uname()
  local sys = (uname.sysname or ""):lower()
  local arch = (uname.machine or ""):lower()

  if is_windows() or sys:find("windows") or sys:find("mingw") or sys:find("msys") then
    return "verbose-windows-x86_64.exe", "verbose.exe"
  elseif sys:find("darwin") then
    return "verbose-macos-arm64", "verbose"
  elseif arch:find("aarch64") or arch:find("arm64") then
    return "verbose-linux-arm64", "verbose"
  else
    return "verbose-linux-x86_64", "verbose"
  end
end

function M.install_dir()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "verbose.nvim", "bin")
end

function M.managed_bin()
  local _, bin_name = M.platform_asset()
  return vim.fs.joinpath(M.install_dir(), bin_name)
end

function M.resolve_bin()
  if config.options.verbose_bin and vim.fn.executable(config.options.verbose_bin) == 1 then
    return config.options.verbose_bin
  end
  local managed = M.managed_bin()
  if vim.fn.executable(managed) == 1 then
    return managed
  end
  local sys_bin = vim.fn.exepath("verbose")
  if sys_bin ~= "" then
    return sys_bin
  end
  return nil
end

function M.download_url(tag)
  local repo = config.options.release_repo or "thetrung/verbose-lang"
  local t = tag or config.options.release_tag or "latest"
  local asset = M.platform_asset()
  if t == "latest" then
    return string.format("https://github.com/%s/releases/latest/download/%s", repo, asset)
  end
  return string.format("https://github.com/%s/releases/download/%s/%s", repo, t, asset)
end

function M.install(opts, on_done)
  opts = opts or {}
  local url = M.download_url(opts.tag)
  local dir = M.install_dir()
  local target = M.managed_bin()
  vim.fn.mkdir(dir, "p")

  if not opts.silent then
    vim.notify("[verbose.nvim] Downloading VerBose compiler from " .. url, vim.log.levels.INFO)
  end

  local tmp = target .. ".tmp"
  local cmd = { "curl", "-fsSL", url, "-o", tmp }
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        pcall(vim.uv.fs_unlink, tmp)
        local msg = "[verbose.nvim] Failed to download verbose: " .. (res.stderr or ("exit " .. tostring(res.code)))
        vim.notify(msg, vim.log.levels.ERROR)
        if on_done then on_done(false, msg) end
        return
      end
      if not is_windows() then
        vim.fn.setfperm(tmp, "rwxr-xr-x")
      end
      vim.uv.fs_rename(tmp, target)
      local ver_out = vim.fn.system({ target, "--version" }):gsub("%s+$", "")
      if not opts.silent then
        vim.notify("[verbose.nvim] Installed: " .. ver_out .. " -> " .. target, vim.log.levels.INFO)
      end
      if on_done then on_done(true, target) end
    end)
  end)
end

return M
