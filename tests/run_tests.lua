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

check("Nested types, nested With, inline With(...), lexical blocks, Task(T), and field gd/hover", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/src", "p")
  vim.fn.writefile({
    "Public Structure Vec3",
    "  Dim x,",
    "      y,",
    "      z As Single",
    "End Structure",
    "Public Structure Transform",
    "  Dim pos, vel As Vec3",
    "End Structure",
    "Public Structure Ship",
    "  Dim tf As Transform",
    "  Dim shield As Integer",
    "End Structure",
  }, tmp .. "/src/world.vb")

  local main_path = tmp .. "/nested.vb"
  local main_lines = {
    'Include "world.vb"',                                                       -- 1
    "Public Function TestNested(flag As Boolean, job As Task(Ship)) As Integer", -- 2
    "  Dim fleet(8) As Ship",                                                    -- 3
    "  Dim s = Ship With ( .tf = Transform With ( .pos = Vec3 With ( .x = 1.0 ) ) ) As Ship", -- 4
    "  Dim deep As Single = fleet(0).tf.pos.z",                                  -- 5
    "  With fleet(0)",                                                           -- 6
    "    .tf.pos.",                                                              -- 7
    "    With .tf",                                                              -- 8
    "      With .pos",                                                           -- 9
    "        .",                                                                 -- 10
    "      End With",                                                            -- 11
    "    End With",                                                              -- 12
    "  End With",                                                                -- 13
    "  Dim initShip As Ship = Ship With (",                                      -- 14
    "    .tf = Transform With (",                                                -- 15
    "      .",                                                                   -- 16
    "    ),",                                                                    -- 17
    "    .",                                                                     -- 18
    "  )",                                                                       -- 19
    "  If flag Then",                                                            -- 20
    "    Dim item As Vec3",                                                      -- 21
    "    item.",                                                                 -- 22
    "  Else",                                                                    -- 23
    "    Dim item As Ship",                                                      -- 24
    "    item.",                                                                 -- 25
    "  End If",                                                                  -- 26
    "  For idx = 0 To 7 Do",                                                     -- 27
    "    Dim z As Single = (Await job).tf.pos.",                                 -- 28
    "  End For",                                                                 -- 29
    "  Return 0",                                                                -- 30
    "End Function",                                                              -- 31
  }
  vim.fn.writefile(main_lines, main_path)

  local function has_label(items, label)
    for _, it in ipairs(items) do
      if it.label == label then return true end
    end
    return false
  end

  index.clear_cache()
  local uri = vim.uri_from_fname(main_path)
  local graph = index.collect_graph(main_path, main_lines)

  -- 1. Multi-line Structure Dim parsed all 3 fields (x, y, z)
  assert(graph.structs["Vec3"] and #graph.structs["Vec3"].fields == 3, "Expected 3 fields in multi-line Vec3")

  -- 2. `Dim s = Ship With (...) As Ship` preserved trailing `As Ship`
  local s_items = lsp.compute_completions(uri, 4, #"  Dim deep As Single = ")
  assert(has_label(s_items, "s"), "Expected local 's' in scope after line 4")
  local s_hov = lsp.compute_hover(uri, 3, 6) -- on `s`
  assert(s_hov and s_hov.contents.value:find("As Ship", 1, true), "Expected hover for 's' to show As Ship")

  -- 3. With-relative chain `.tf.pos.` inside `With fleet(0)` (line 7, 0-indexed 6)
  local wc_items = lsp.compute_completions(uri, 6, #"    .tf.pos.")
  assert(has_label(wc_items, "z"), "Expected Vec3 field 'z' on .tf.pos. inside With fleet(0)")

  -- 4. Nested `With fleet(0)` -> `With .tf` -> `With .pos` -> bare `.` (line 10, 0-indexed 9)
  local nw_items = lsp.compute_completions(uri, 9, #"        .")
  assert(has_label(nw_items, "y"), "Expected Vec3 field 'y' inside nested With .tf -> With .pos")

  -- 5. Nested multi-line inline `Ship With ( .tf = Transform With ( . ) , . )`
  local inner_init = lsp.compute_completions(uri, 15, #"      .")
  assert(has_label(inner_init, "pos") and has_label(inner_init, "vel"), "Expected Transform fields inside inner Transform With (")
  local outer_init = lsp.compute_completions(uri, 17, #"    .")
  assert(has_label(outer_init, "shield") and has_label(outer_init, "tf"), "Expected Ship fields inside outer Ship With (")

  -- 6. Lexical block shadowing: `item` is Vec3 in If branch (line 22) and Ship in Else branch (line 25)
  local if_items = lsp.compute_completions(uri, 21, #"    item.")
  assert(has_label(if_items, "x") and not has_label(if_items, "shield"), "Expected item to be Vec3 in If branch")
  local else_items = lsp.compute_completions(uri, 24, #"    item.")
  assert(has_label(else_items, "shield") and not has_label(else_items, "x"), "Expected item to be Ship in Else branch")

  -- 7. For loop variable `idx` visible inside loop (line 28) and NOT outside (line 30)
  local in_for = lsp.compute_completions(uri, 27, #"    ")
  assert(has_label(in_for, "idx"), "Expected For loop var 'idx' inside For block")
  local out_for = lsp.compute_completions(uri, 29, #"  ")
  assert(not has_label(out_for, "idx"), "Did not expect For loop var 'idx' after End For")

  -- 8. `(Await job).tf.pos.` unwraps `Task(Ship)` -> `Ship` -> `Transform` -> `Vec3`
  local await_items = lsp.compute_completions(uri, 27, #"    Dim z As Single = (Await job).tf.pos.")
  assert(has_label(await_items, "z"), "Expected Vec3 field 'z' on (Await job).tf.pos.")

  -- 9. Nested field go-to-definition & hover on `fleet(0).tf.pos.z` (middle & leaf segments + local var + inline With)
  local z_col = #"  Dim deep As Single = fleet(0).tf.pos."
  local fdef = lsp.compute_definition(uri, 4, z_col)
  assert(fdef and fdef.uri:find("world.vb", 1, true) and fdef.range.start.line == 3, "Expected gd on .z to jump to world.vb:4")
  local fhov = lsp.compute_hover(uri, 4, z_col)
  assert(fhov and fhov.contents.value:find("Vec3.z As Single", 1, true), "Expected hover on .z to show Vec3.z As Single")

  local pos_col = #"  Dim deep As Single = fleet(0).tf."
  local pdef = lsp.compute_definition(uri, 4, pos_col)
  assert(pdef and pdef.uri:find("world.vb", 1, true) and pdef.range.start.line == 6, "Expected gd on .pos to jump to world.vb:7")

  local fleet_col = #"  Dim deep As Single = "
  local ldef = lsp.compute_definition(uri, 4, fleet_col)
  assert(ldef and ldef.uri:find("nested.vb", 1, true) and ldef.range.start.line == 2, "Expected gd on local 'fleet' to jump to Dim line 3")

  local inline_x_col = main_lines[4]:find(".x", 1, true) -- 0-based index of 'x'
  local xdef = lsp.compute_definition(uri, 3, inline_x_col)
  assert(xdef and xdef.uri:find("world.vb", 1, true) and xdef.range.start.line == 1, "Expected gd on inline With .x to jump to world.vb:2")

  vim.fn.delete(tmp, "rf")
end)

print(string.format("\nSummary: %d/%d tests passed, %d failed.", passed, passed + failed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
