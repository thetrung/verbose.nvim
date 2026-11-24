-- Headless Neovim verification suite for verbose.nvim
-- Run via: nvim --headless -u NONE -c "set rtp+=." -l tests/run_tests.lua

vim.opt.rtp:prepend(vim.fn.getcwd())

local passed = 0
local failed = 0

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("[PASS] " .. name)
  else
    failed = failed + 1
    print("[FAIL] " .. name .. ": " .. tostring(err))
  end
end

local verbose = require("verbose")
local index = require("verbose.index")
local lsp = require("verbose.lsp")
local installer = require("verbose.installer")

verbose.setup({
  diagnostics = { enabled = false },
})

check("Filetype detection registers .vb -> verbose", function()
  dofile("ftdetect/verbose.lua")
  local ft = vim.filetype.match({ filename = "hello.vb" })
  assert(ft == "verbose", "expected filetype verbose, got " .. tostring(ft))
end)

check("Tree-sitter parser loads and parses VerBose-Lang cleanly", function()
  local parser_path = vim.fs.joinpath(vim.fn.getcwd(), "parser", "verbose.so")
  assert(vim.fn.filereadable(parser_path) == 1, "parser/verbose.so missing")
  vim.treesitter.language.add("verbose", { path = parser_path })
  local sample = [[
Include "raylib.vb"

Public Structure Vec2
  Dim x, y As Single
End Structure

Public Function Add(a, b As Integer) As Integer
  Dim msg As String = $"sum={a + b}"
  Match a With
    Case 0 Then Return b
    Case _ Then Return a + b
  End Match
End Function
]]
  local parser = vim.treesitter.get_string_parser(sample, "verbose")
  local tree = parser:parse()[1]
  local root = tree:root()
  assert(not root:has_error(), "Tree-sitter reported syntax errors: " .. root:sexpr())
end)

check("All Tree-sitter queries (highlights, locals, folds, indents) compile cleanly", function()
  for _, qname in ipairs({ "highlights", "locals", "folds", "indents" }) do
    local q = vim.treesitter.query.get("verbose", qname)
    assert(q ~= nil, qname .. " query failed to load")
  end
end)

check("Recursive Include graph cache indexes multi-file project", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/src", "p")
  vim.fn.writefile({
    "Public Structure Hero",
    "  Dim hp, mp As Integer",
    "  Dim name As String",
    "End Structure",
    "Public Enum HeroClass",
    "  CLASS_MAGE = 0",
    "  CLASS_KNIGHT = 1",
    "End Enum",
    "' Heals a hero by amount",
    "Public Sub HealHero(ByRef h As Hero, amount As Integer)",
    "  h.hp = h.hp + amount",
    "End Sub",
  }, tmp .. "/src/hero.vb")

  local main_path = tmp .. "/main.vb"
  local main_lines = {
    'Include "hero.vb"',
    "Public Function main() As Integer",
    "  Dim player As Hero",
    "  player.",
    "  Dim cls As Integer = HeroClass.",
    "  With player",
    "    .",
    "  End With",
    "  HealHero(ByRef player, 10)",
    "  Return 0",
    "End Function",
  }
  vim.fn.writefile(main_lines, main_path)

  index.clear_cache()
  local graph = index.collect_graph(main_path, main_lines)
  assert(graph.structs["Hero"] ~= nil, "Hero struct not indexed from Include")
  assert(graph.enums["HeroClass"] ~= nil, "HeroClass enum not indexed from Include")
  assert(graph.functions["HealHero"] ~= nil, "HealHero sub not indexed from Include")
  local n = index.cache_stats()
  assert(n >= 2, "Expected >=2 cached files, got " .. tostring(n))

  local uri = vim.uri_from_fname(main_path)

  -- Struct field completion on `player.`
  local fitems = lsp.compute_completions(uri, 3, #"  player.")
  local has_hp = false
  for _, it in ipairs(fitems) do
    if it.label == "hp" then has_hp = true end
  end
  assert(has_hp, "Expected struct field 'hp' completion on player.")

  -- Enum member completion on `HeroClass.`
  local eitems = lsp.compute_completions(uri, 4, #"  Dim cls As Integer = HeroClass.")
  local has_mage = false
  for _, it in ipairs(eitems) do
    if it.label == "CLASS_MAGE" then has_mage = true end
  end
  assert(has_mage, "Expected enum member 'CLASS_MAGE' completion on HeroClass.")

  -- With-block `.field` completion inside `With player`
  local witems = lsp.compute_completions(uri, 6, #"    .")
  local has_mp = false
  for _, it in ipairs(witems) do
    if it.label == "mp" then has_mp = true end
  end
  assert(has_mp, "Expected With-block field 'mp' completion on bare '.'")

  -- Cross-file go-to-definition on `HealHero`
  local def = lsp.compute_definition(uri, 8, 4)
  assert(def ~= nil and def.uri:find("hero.vb", 1, true), "Expected definition in hero.vb")

  -- Cross-file hover on `HealHero`
  local hov = lsp.compute_hover(uri, 8, 4)
  assert(hov ~= nil and hov.contents.value:find("Heals a hero", 1, true), "Expected doc comment in hover")

  -- Signature help inside `HealHero(ByRef player, `
  local sig = lsp.compute_signature_help(uri, 8, #"  HealHero(ByRef player, ")
  assert(sig ~= nil and sig.activeParameter == 1, "Expected signatureHelp activeParameter=1")

  vim.fn.delete(tmp, "rf")
end)

check("Installer resolves platform asset & download URL for latest VerBose release", function()
  local asset, bin = installer.platform_asset()
  assert(asset ~= "" and bin ~= "", "Empty platform asset")
  local url = installer.download_url("latest")
  assert(url:find("https://github.com/thetrung/verbose-lang/releases/latest/download/", 1, true), "Unexpected URL: " .. url)
end)

print(string.format("\nSummary: %d/%d tests passed, %d failed.", passed, passed + failed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
