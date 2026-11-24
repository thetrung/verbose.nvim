-- In-process Neovim LSP server for VerBose-Lang (zero external runtime dependencies)
-- Provides completion, .field / Enum. member completion, Include path completion,
-- go-to-definition across Included files, hover, documentSymbol, signatureHelp, and diagnostics.
local config = require("verbose.config")
local index = require("verbose.index")
local installer = require("verbose.installer")

local M = {}

local KEYWORDS = {
  "Include", "Public", "Private", "Declare", "Structure", "Enum", "Static", "Volatile",
  "Function", "Sub", "End", "Dim", "As", "ByRef", "With", "Return", "Test", "Assert",
  "If", "Then", "Else", "While", "Do", "For", "To", "Match", "Select", "Case", "When",
  "And", "Or", "Xor", "Not", "Mod", "Shl", "Shr", "True", "False", "Nothing",
  "Label", "GoTo", "Async", "Await", "At",
}

local TYPES = {
  { name = "Integer", doc = "32-bit signed integer (`i32`)" },
  { name = "Byte", doc = "8-bit unsigned integer (`i8`)" },
  { name = "Short", doc = "16-bit signed integer (`i16`)" },
  { name = "Long", doc = "64-bit signed integer (`i64`)" },
  { name = "Single", doc = "32-bit IEEE 754 float (`float`)" },
  { name = "Double", doc = "64-bit IEEE 754 float (`double`)" },
  { name = "Boolean", doc = "Boolean (`i1`)" },
  { name = "Pointer", doc = "Opaque raw pointer (`ptr`)" },
  { name = "String", doc = "Null-terminated UTF-8 string alias for `Pointer`" },
  { name = "Arena", doc = "Deterministic zero-GC bump allocator handle" },
  { name = "Task", doc = "Structured concurrency handle (`Task` or `Task(T)`)" },
}

local BUILTINS = {
  { name = "SizeOf", sig = "SizeOf(Type) As Integer", doc = "Compile-time byte size of a primitive or Structure type." },
  { name = "Len", sig = "Len(arr) As Integer", doc = "Returns the length of a fixed array or slice." },
  { name = "ArenaCreate", sig = "ArenaCreate(capacity As Integer) As Arena", doc = "Allocates a new bump Arena of `capacity` bytes." },
  { name = "ArenaFromBuffer", sig = "ArenaFromBuffer(ByRef buf, capacity As Integer) As Arena", doc = "Creates an Arena backed by an existing stack/static byte buffer." },
  { name = "ArenaAlloc", sig = "ArenaAlloc(ByRef arena As Arena, Type, count As Integer) As Type()", doc = "Zero-initialized typed slice bump allocation from an Arena." },
  { name = "ArenaAllocBytes", sig = "ArenaAllocBytes(ByRef arena As Arena, bytes As Integer) As Pointer", doc = "Zero-initialized raw byte allocation from an Arena." },
  { name = "ArenaReset", sig = "ArenaReset(ByRef arena As Arena)", doc = "O(1) resets the Arena bump pointer to zero." },
  { name = "ArenaMark", sig = "ArenaMark(ByRef arena As Arena) As Integer", doc = "Captures current Arena offset for scoped rewind." },
  { name = "ArenaRewind", sig = "ArenaRewind(ByRef arena As Arena, mark As Integer)", doc = "Rewinds Arena offset back to a previously captured mark." },
  { name = "ArenaDestroy", sig = "ArenaDestroy(ByRef arena As Arena)", doc = "Frees the Arena backing memory." },
  { name = "IsNull", sig = "IsNull(ptr As Pointer) As Boolean", doc = "Checks whether a Pointer is null (`Nothing`)." },
  { name = "HeapAlloc", sig = "HeapAlloc(Type, count As Integer) As Pointer", doc = "Allocates `count` elements on the C heap." },
  { name = "HeapRealloc", sig = "HeapRealloc(ptr As Pointer, Type, count As Integer) As Pointer", doc = "Resizes a heap allocation." },
  { name = "HeapFree", sig = "HeapFree(ptr As Pointer)", doc = "Frees a heap allocation." },
  { name = "AddressOf", sig = "AddressOf(lvalue) As Pointer", doc = "Takes raw `Pointer` address of a variable, field, element, or function." },
  { name = "PtrRead", sig = "PtrRead(addr As Pointer, Type) As Type", doc = "Non-volatile typed read from a raw pointer." },
  { name = "PtrWrite", sig = "PtrWrite(addr As Pointer, Type, val As Type)", doc = "Non-volatile typed write to a raw pointer." },
  { name = "PtrAdd", sig = "PtrAdd(addr As Pointer, byteOffset As Integer) As Pointer", doc = "Byte-level pointer offset arithmetic." },
  { name = "VolatileLoad", sig = "VolatileLoad(addr As Pointer, Type) As Type", doc = "LLVM volatile typed load for MMIO registers." },
  { name = "VolatileStore", sig = "VolatileStore(addr As Pointer, Type, val As Type)", doc = "LLVM volatile typed store for MMIO registers." },
  { name = "Printf", sig = "Printf(fmt As String, ...) As Integer", doc = "C stdio formatted output." },
}

-- Buffer text cache keyed by URI
local buf_docs = {}
local diag_ns = vim.api.nvim_create_namespace("verbose_diagnostics")

local function uri_to_path(uri)
  return vim.uri_to_fname(uri)
end

local function get_lines_for_uri(uri)
  if buf_docs[uri] then
    return buf_docs[uri]
  end
  local path = uri_to_path(uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

-- Resolve active scope & variable type at 1-based `lnum`
local function find_scope_at(entry, lnum)
  if not entry then return nil end
  for _, sc in ipairs(entry.scopes or {}) do
    if lnum >= sc.start_line and lnum <= sc.end_line then
      return sc
    end
  end
  return nil
end

-- Resolve the type of a simple expression like `ball`, `particles(i)`, `ball.pos`
local function resolve_expr_type(expr, scope, graph)
  local cur = expr:gsub("^%s+", ""):gsub("%s+$", "")
  -- Strip array index suffix: `particles(i)` -> `particles`
  local parts = {}
  for seg in cur:gmatch("[^%.]+") do
    local base = seg:gsub("%b()", "")
    table.insert(parts, base)
  end
  if #parts == 0 then return nil end

  local root_name = parts[1]
  local ty = nil
  if scope and scope.vars[root_name] then
    ty = scope.vars[root_name]
  elseif graph.statics[root_name] then
    ty = graph.statics[root_name].type
  elseif graph.functions[root_name] then
    ty = graph.functions[root_name].ret
  end
  if not ty then return nil end
  ty = ty:gsub("%(%)$", "")

  for i = 2, #parts do
    local st = graph.structs[ty]
    if not st then return nil end
    local next_ty = nil
    for _, f in ipairs(st.fields) do
      if f.name == parts[i] then
        next_ty = f.type:gsub("%(%)$", "")
        break
      end
    end
    if not next_ty then return nil end
    ty = next_ty
  end
  return ty
end

-- Determine innermost `With <target>` struct type at 1-based `lnum`
local function resolve_with_type(scope, lnum, graph)
  if not scope then return nil end
  local best = nil
  for _, wb in ipairs(scope.with_blocks or {}) do
    if lnum > wb.start_line and lnum < wb.end_line then
      best = wb
    end
  end
  if not best then return nil end
  return resolve_expr_type(best.target, scope, graph)
end

local function word_at(line, col0)
  local before = line:sub(1, col0)
  local after = line:sub(col0 + 1)
  local left = before:match("([A-Za-z_][A-Za-z0-9_]*)$") or ""
  local right = after:match("^([A-Za-z0-9_]*)") or ""
  return left .. right, before
end

-- Build LSP completion items
function M.compute_completions(uri, line0, col0)
  local path = uri_to_path(uri)
  local lines = get_lines_for_uri(uri)
  local graph = index.collect_graph(path, lines)
  local lnum = line0 + 1
  local line = lines[lnum] or ""
  local before = line:sub(1, col0)
  local scope = find_scope_at(graph.root, lnum)
  local items = {}

  -- 1. Include "..." file completion
  local inc_prefix = before:match('^%s*Include%s+"([^"]*)$')
  if inc_prefix then
    local seen = {}
    for _, dir in ipairs(index.search_dirs(path)) do
      local scan = vim.fn.globpath(dir, "**/*.vb", false, true)
      for _, f in ipairs(scan) do
        local rel = f:sub(#dir + 2)
        if not seen[rel] then
          seen[rel] = true
          table.insert(items, {
            label = rel,
            kind = 17, -- File
            detail = dir,
          })
        end
      end
    end
    return items
  end

  -- 2. Member completion: `expr.prefix` or bare `.prefix` inside With
  local recv, _ = before:match("([A-Za-z_][A-Za-z0-9_%.%(%)]*)%.([A-Za-z0-9_]*)$")
  if recv then
    -- Enum.Member?
    local en = graph.enums[recv]
    if en then
      for _, m in ipairs(en.members) do
        table.insert(items, {
          label = m.name,
          kind = 20, -- EnumMember
          detail = en.name .. "." .. m.name .. (m.value and (" = " .. m.value) or ""),
        })
      end
      return items
    end
    -- Struct variable field completion
    local ty = resolve_expr_type(recv, scope, graph)
    if ty and graph.structs[ty] then
      for _, f in ipairs(graph.structs[ty].fields) do
        table.insert(items, {
          label = f.name,
          kind = 5, -- Field
          detail = f.name .. " As " .. f.type,
        })
      end
      return items
    end
  elseif before:match("[^A-Za-z0-9_%.]%.([A-Za-z0-9_]*)$") or before:match("^%s*%.([A-Za-z0-9_]*)$") then
    local wty = resolve_with_type(scope, lnum, graph)
    if wty and graph.structs[wty] then
      for _, f in ipairs(graph.structs[wty].fields) do
        table.insert(items, {
          label = f.name,
          kind = 5, -- Field
          detail = "(With " .. wty .. ") " .. f.name .. " As " .. f.type,
        })
      end
      return items
    end
  end

  -- 3. General completion: locals, functions, structs, enums, unqualified enum members, statics, builtins, types, keywords
  local added = {}
  local function push(item)
    if not added[item.label] then
      added[item.label] = true
      table.insert(items, item)
    end
  end

  if scope then
    for vname, vtype in pairs(scope.vars) do
      push({ label = vname, kind = 6, detail = "Dim " .. vname .. " As " .. vtype })
    end
  end

  for name, fn in pairs(graph.functions) do
    push({
      label = name,
      kind = 3, -- Function
      detail = fn.sig,
      documentation = fn.doc and { kind = "markdown", value = fn.doc } or nil,
    })
  end

  for name, st in pairs(graph.structs) do
    local fnames = {}
    for _, f in ipairs(st.fields) do
      table.insert(fnames, f.name .. ": " .. f.type)
    end
    push({
      label = name,
      kind = 22, -- Struct
      detail = "Structure " .. name,
      documentation = { kind = "markdown", value = "Fields: `" .. table.concat(fnames, ", ") .. "`" },
    })
  end

  for name, en in pairs(graph.enums) do
    push({ label = name, kind = 13, detail = "Enum " .. name .. " (" .. #en.members .. " members)" })
  end

  for mname, slot in pairs(graph.enum_members) do
    if slot.count == 1 then
      local m = slot.member
      push({
        label = mname,
        kind = 20, -- EnumMember
        detail = m.enum_name .. "." .. m.name .. (m.value and (" = " .. m.value) or ""),
      })
    end
  end

  for name, st in pairs(graph.statics) do
    push({ label = name, kind = 21, detail = "Static " .. name .. " As " .. st.type })
  end

  for _, b in ipairs(BUILTINS) do
    push({
      label = b.name,
      kind = 3,
      detail = b.sig,
      documentation = { kind = "markdown", value = b.doc },
    })
  end

  for _, t in ipairs(TYPES) do
    push({
      label = t.name,
      kind = 25, -- TypeParameter / Type
      detail = "Built-in Type",
      documentation = { kind = "markdown", value = t.doc },
    })
  end

  for _, kw in ipairs(KEYWORDS) do
    push({ label = kw, kind = 14, detail = "Keyword" })
  end

  return items
end

function M.compute_definition(uri, line0, col0)
  local path = uri_to_path(uri)
  local lines = get_lines_for_uri(uri)
  local lnum = line0 + 1
  local line = lines[lnum] or ""

  -- Jump to Include "..." target file
  local inc = line:match('^%s*Include%s+"([^"]+)"')
  if inc then
    local target = index.resolve_include(path, inc)
    if target then
      return {
        uri = vim.uri_from_fname(target),
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      }
    end
  end

  local graph = index.collect_graph(path, lines)
  local word = word_at(line, col0)
  if word == "" then return nil end

  local target = graph.functions[word]
    or graph.structs[word]
    or graph.enums[word]
    or graph.statics[word]

  if not target and graph.enum_members[word] then
    target = graph.enum_members[word].member
  end

  if target and target.path then
    local tl = math.max(0, (target.line or 1) - 1)
    local tc = math.max(0, (target.col or 1) - 1)
    return {
      uri = vim.uri_from_fname(target.path),
      range = { start = { line = tl, character = tc }, ["end"] = { line = tl, character = tc + #word } },
    }
  end
  return nil
end

function M.compute_hover(uri, line0, col0)
  local path = uri_to_path(uri)
  local lines = get_lines_for_uri(uri)
  local lnum = line0 + 1
  local line = lines[lnum] or ""
  local graph = index.collect_graph(path, lines)
  local word = word_at(line, col0)
  if word == "" then return nil end

  local md = {}
  if graph.functions[word] then
    local fn = graph.functions[word]
    table.insert(md, "```verbose\n" .. fn.sig .. "\n```")
    if fn.doc then table.insert(md, fn.doc) end
    table.insert(md, "_Defined in `" .. vim.fs.basename(fn.path) .. ":" .. fn.line .. "`_")
  elseif graph.structs[word] then
    local st = graph.structs[word]
    local body = { "Structure " .. st.name }
    for _, f in ipairs(st.fields) do
      table.insert(body, "  Dim " .. f.name .. " As " .. f.type)
    end
    table.insert(body, "End Structure")
    table.insert(md, "```verbose\n" .. table.concat(body, "\n") .. "\n```")
    if st.doc then table.insert(md, st.doc) end
    table.insert(md, "_Defined in `" .. vim.fs.basename(st.path) .. ":" .. st.line .. "`_")
  elseif graph.enums[word] then
    local en = graph.enums[word]
    local body = { "Enum " .. en.name }
    for i, m in ipairs(en.members) do
      if i <= 12 then
        table.insert(body, "  " .. m.name .. (m.value and (" = " .. m.value) or ""))
      end
    end
    if #en.members > 12 then
      table.insert(body, "  ' ... (" .. (#en.members - 12) .. " more)")
    end
    table.insert(body, "End Enum")
    table.insert(md, "```verbose\n" .. table.concat(body, "\n") .. "\n```")
  elseif graph.enum_members[word] then
    local m = graph.enum_members[word].member
    table.insert(md, "```verbose\n" .. m.enum_name .. "." .. m.name .. (m.value and (" = " .. m.value) or "") .. "\n```")
  elseif graph.statics[word] then
    local st = graph.statics[word]
    table.insert(md, "```verbose\nStatic " .. st.name .. " As " .. st.type .. "\n```")
    if st.doc then table.insert(md, st.doc) end
  else
    for _, b in ipairs(BUILTINS) do
      if b.name == word then
        table.insert(md, "```verbose\n" .. b.sig .. "\n```")
        table.insert(md, b.doc)
        break
      end
    end
    if #md == 0 then
      for _, t in ipairs(TYPES) do
        if t.name == word then
          table.insert(md, "**" .. t.name .. "** — " .. t.doc)
          break
        end
      end
    end
  end

  if #md == 0 then return nil end
  return { contents = { kind = "markdown", value = table.concat(md, "\n\n") } }
end

function M.compute_document_symbols(uri)
  local path = uri_to_path(uri)
  local lines = get_lines_for_uri(uri)
  local entry = index.index_file(path, lines)
  if not entry then return {} end

  local syms = {}
  local kind_map = {
    Structure = 23,
    Enum = 10,
    Function = 12,
    Sub = 12,
    ["Declare Function"] = 12,
    ["Declare Sub"] = 12,
    Static = 14,
  }

  for _, sym in ipairs(entry.symbols) do
    local l = math.max(0, (sym.line or 1) - 1)
    local c = math.max(0, (sym.col or 1) - 1)
    local range = { start = { line = l, character = c }, ["end"] = { line = l, character = c + #sym.name } }
    table.insert(syms, {
      name = sym.name,
      detail = sym.sig or sym.type or sym.kind,
      kind = kind_map[sym.kind] or 13,
      range = range,
      selectionRange = range,
    })
  end
  return syms
end

function M.compute_signature_help(uri, line0, col0)
  local path = uri_to_path(uri)
  local lines = get_lines_for_uri(uri)
  local line = lines[line0 + 1] or ""
  local before = line:sub(1, col0)

  -- Find enclosing function call `FuncName(arg1, arg2`
  local depth = 0
  local commas = 0
  local open_pos = nil
  for i = #before, 1, -1 do
    local ch = before:sub(i, i)
    if ch == ")" then depth = depth + 1
    elseif ch == "(" then
      if depth == 0 then open_pos = i break end
      depth = depth - 1
    elseif ch == "," and depth == 0 then
      commas = commas + 1
    end
  end
  if not open_pos then return nil end

  local fname = before:sub(1, open_pos - 1):match("([A-Za-z_][A-Za-z0-9_]*)%s*$")
  if not fname then return nil end

  local graph = index.collect_graph(path, lines)
  local fn = graph.functions[fname]
  if not fn then return nil end

  local params = {}
  for _, p in ipairs(fn.param_list or {}) do
    table.insert(params, { label = p.name .. " As " .. p.type })
  end

  return {
    signatures = {
      {
        label = fn.sig,
        documentation = fn.doc,
        parameters = params,
      },
    },
    activeSignature = 0,
    activeParameter = math.min(commas, math.max(0, #params - 1)),
  }
end

-- Run `verbose --emit-only` asynchronously to populate real compiler diagnostics
function M.run_diagnostics(bufnr)
  if not config.options.diagnostics.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" or vim.fn.filereadable(path) ~= 1 then return end

  local bin = installer.resolve_bin()
  if not bin then return end

  local tmp_ll = vim.fn.tempname() .. ".ll"
  local args = { bin, path, "--emit-only", "-o", tmp_ll }
  for _, d in ipairs(index.search_dirs(path)) do
    table.insert(args, "-I")
    table.insert(args, d)
  end

  vim.system(args, { text = true }, function(res)
    pcall(vim.uv.fs_unlink, tmp_ll)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      local diags = {}
      if res.code ~= 0 then
        local combined = (res.stderr or "") .. "\n" .. (res.stdout or "")
        for err_line in combined:gmatch("[^\r\n]+") do
          if err_line:find("error", 1, true) or err_line:find("Error", 1, true) then
            local ln = tonumber(err_line:match("at line (%d+)")) or tonumber(err_line:match("line (%d+)")) or 1
            table.insert(diags, {
              lnum = math.max(0, ln - 1),
              col = 0,
              severity = vim.diagnostic.severity.ERROR,
              source = "verbose",
              message = err_line,
            })
          end
        end
      end
      vim.diagnostic.set(diag_ns, bufnr, diags, {})
    end)
  end)
end

-- In-process Neovim LSP RPC server factory
local function make_rpc_server()
  return function(dispatchers)
    local closing = false
    local req_id = 0

    local srv = {}

    function srv.request(method, params, callback)
      req_id = req_id + 1
      local result = nil

      if method == "initialize" then
        result = {
          capabilities = {
            textDocumentSync = 1, -- Full sync
            completionProvider = {
              triggerCharacters = { ".", '"' },
              resolveProvider = false,
            },
            definitionProvider = true,
            hoverProvider = true,
            documentSymbolProvider = true,
            signatureHelpProvider = {
              triggerCharacters = { "(", "," },
            },
          },
          serverInfo = { name = "verbose_ls", version = "0.1.0" },
        }
      elseif method == "shutdown" then
        result = vim.NIL
      elseif method == "textDocument/completion" then
        local items = M.compute_completions(params.textDocument.uri, params.position.line, params.position.character)
        result = { isIncomplete = false, items = items }
      elseif method == "textDocument/definition" then
        result = M.compute_definition(params.textDocument.uri, params.position.line, params.position.character)
      elseif method == "textDocument/hover" then
        result = M.compute_hover(params.textDocument.uri, params.position.line, params.position.character)
      elseif method == "textDocument/documentSymbol" then
        result = M.compute_document_symbols(params.textDocument.uri)
      elseif method == "textDocument/signatureHelp" then
        result = M.compute_signature_help(params.textDocument.uri, params.position.line, params.position.character)
      end

      vim.schedule(function()
        callback(nil, result)
      end)
      return true, req_id
    end

    function srv.notify(method, params)
      if method == "exit" then
        closing = true
        dispatchers.on_exit(0, 0)
      elseif method == "textDocument/didOpen" and params.textDocument then
        local uri = params.textDocument.uri
        buf_docs[uri] = vim.split(params.textDocument.text or "", "\n", { plain = true })
        index.collect_graph(uri_to_path(uri), buf_docs[uri])
      elseif method == "textDocument/didChange" and params.textDocument and params.contentChanges then
        local last = params.contentChanges[#params.contentChanges]
        if last and last.text then
          local uri = params.textDocument.uri
          buf_docs[uri] = vim.split(last.text, "\n", { plain = true })
          index.index_file(uri_to_path(uri), buf_docs[uri])
        end
      elseif method == "textDocument/didClose" and params.textDocument then
        buf_docs[params.textDocument.uri] = nil
      end
      return true
    end

    function srv.is_closing()
      return closing
    end

    function srv.terminate()
      closing = true
      dispatchers.on_exit(0, 0)
    end

    return srv
  end
end

function M.attach(bufnr)
  if not config.options.lsp.enabled then return end
  local path = vim.api.nvim_buf_get_name(bufnr)
  local root = path ~= "" and index.find_project_root(path) or vim.fn.getcwd()
  vim.lsp.start({
    name = "verbose_ls",
    cmd = make_rpc_server(),
    root_dir = root,
  }, { bufnr = bufnr })
end

-- Fallback omnifunc if LSP is disabled
function M.omnifunc(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  if findstart == 1 then
    local start = col
    while start > 0 and line:sub(start, start):match("[%w_]") do
      start = start - 1
    end
    return start
  end
  local uri = vim.uri_from_bufnr(0)
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
  local items = M.compute_completions(uri, lnum, col)
  local matches = {}
  local low = base:lower()
  for _, it in ipairs(items) do
    if it.label:lower():find(low, 1, true) == 1 then
      table.insert(matches, { word = it.label, menu = it.detail or "" })
    end
  end
  return matches
end

return M
