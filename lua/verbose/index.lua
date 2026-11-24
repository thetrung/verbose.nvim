-- Fast VerBose-Lang symbol indexer & recursive Include graph cache (mtime-invalidated)
local config = require("verbose.config")

local M = {}

-- Cache keyed by normalized absolute path -> { mtime, size, entry }
M.cache = {}

local function norm_path(p)
  return vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_comment(line)
  local in_str = false
  local i = 1
  local n = #line
  while i <= n do
    local ch = line:sub(i, i)
    if ch == '"' then
      in_str = not in_str
    elseif ch == "\\" and in_str then
      i = i + 1
    elseif ch == "'" and not in_str then
      return line:sub(1, i - 1)
    end
    i = i + 1
  end
  return line
end

-- Parse grouped declarator list like: "a, b As Single, c As Integer = 0"
-- Supports fixed/slice arrays ("arr(64) As Foo", "s() As Bar"), parameterized types ("t As Task(Hero)"),
-- and inline struct initializers ("p = Hero With (.hp = 10) As Hero").
-- Returns list of { name, type }
local function parse_grouped_decls(spec)
  local out = {}
  -- Strip balanced inline `With (...)` initializers so commas/parens inside don't confuse splitting,
  -- while preserving any trailing `As Type` after the closing `)`.
  local cleaned = spec:gsub("With%s*%b()", "")
  -- If an unclosed multi-line `With (` remains at end of line, strip it.
  cleaned = cleaned:gsub("%s+With%s*%(.*$", "")

  -- Split by commas outside parentheses
  local parts = {}
  local depth = 0
  local start = 1
  for i = 1, #cleaned do
    local ch = cleaned:sub(i, i)
    if ch == "(" then depth = depth + 1
    elseif ch == ")" then depth = math.max(0, depth - 1)
    elseif ch == "," and depth == 0 then
      table.insert(parts, trim(cleaned:sub(start, i - 1)))
      start = i + 1
    end
  end
  table.insert(parts, trim(cleaned:sub(start)))

  local function match_type_name(s)
    -- Match `Task(Hero)`, `Hero()`, or `Hero`
    local t = s:match("^([A-Za-z_][A-Za-z0-9_]*%s*%b())")
    if t then return (t:gsub("%s+", "")) end
    return s:match("^([A-Za-z_][A-Za-z0-9_]*)")
  end

  local function match_trailing_type(s)
    local after_as = s:match("%s+As%s+(.+)$")
    if not after_as then return nil end
    return match_type_name(trim(after_as))
  end

  local pending = {}
  for _, raw in ipairs(parts) do
    local item = raw:gsub("^ByRef%s+", "")
    local eq_pos = item:find("=", 1, true)
    local left = eq_pos and trim(item:sub(1, eq_pos - 1)) or item
    local right = eq_pos and trim(item:sub(eq_pos + 1)) or ""

    -- Type might be on `left` ("x As Integer", "x(10) As Task(Hero)") or on `right` after value ("x = 1 As Integer")
    local name, after_as = left:match("^([A-Za-z_][A-Za-z0-9_]*)%s*%(?[^)]*%)?%s+As%s+(.+)$")
    local ty = after_as and match_type_name(trim(after_as)) or nil
    if not name then
      name = left:match("^([A-Za-z_][A-Za-z0-9_]*)")
      if right ~= "" then
        ty = match_trailing_type(right)
      end
    end

    if name then
      if ty then
        for _, p in ipairs(pending) do
          table.insert(out, { name = p, type = ty })
        end
        pending = {}
        table.insert(out, { name = name, type = ty })
      else
        table.insert(pending, name)
      end
    end
  end
  for _, p in ipairs(pending) do
    table.insert(out, { name = p, type = "Any" })
  end
  return out
end

-- Helper to create a lexical block node inside a function/sub/test scope
local function new_block(kind, start_line, end_line, parent)
  local blk = {
    kind = kind,
    start_line = start_line,
    end_line = end_line,
    parent = parent,
    vars = {},     -- list of { name, type, line, col, path, kind }
    children = {},
  }
  if parent then
    table.insert(parent.children, blk)
  end
  return blk
end

-- Return map of visible local variables (name -> var_info) at 1-based `lnum` inside `scope`.
-- Respects lexical nesting (If/Else/While/For/Match/Case/With) and declaration line order.
function M.visible_vars_at(scope, lnum)
  local vars = {}
  if not scope then return vars end

  local function collect(blk)
    if not blk then return end
    if lnum < blk.start_line or lnum > blk.end_line then return end
    for _, v in ipairs(blk.vars) do
      if v.line <= lnum then
        vars[v.name] = v
      end
    end
    for _, child in ipairs(blk.children) do
      if lnum >= child.start_line and lnum <= child.end_line then
        collect(child)
      end
    end
  end

  if scope.root_block then
    collect(scope.root_block)
  else
    for name, ty in pairs(scope.vars or {}) do
      vars[name] = { name = name, type = ty, line = scope.start_line, col = 1, kind = "Dim" }
    end
  end
  return vars
end

function M.parse_lines(lines, filepath)
  local entry = {
    path = filepath,
    includes = {},     -- { raw, line }
    symbols = {},      -- all top-level symbols
    structs = {},      -- name -> { name, line, col, path, doc, fields = { {name, type, line} } }
    enums = {},        -- name -> { name, line, col, path, doc, members = { {name, value, line} } }
    functions = {},    -- name -> { name, kind, params, param_list, ret, sig, line, col, path, doc, is_private, is_async }
    statics = {},      -- name -> { name, type, line, col, path, doc, is_private }
    scopes = {},       -- { { start_line, end_line, vars = { name -> type }, with_stack = { {start_line, end_line, expr} } } }
  }

  local pending_doc = {}
  local cur_struct = nil
  local struct_dim_buf = nil -- { text = "...", chunks = { { raw, line } } } for multi-line Structure Dim
  local cur_enum = nil
  local cur_scope = nil
  local block_stack = {}
  local open_withs = {}

  local function flush_struct_dim()
    if not cur_struct or not struct_dim_buf then return end
    for _, decl in ipairs(parse_grouped_decls(struct_dim_buf.text)) do
      local fline = struct_dim_buf.chunks[1].line
      local fcol = 1
      for _, ch in ipairs(struct_dim_buf.chunks) do
        local pos = ch.raw:find("%f[%w_]" .. decl.name .. "%f[^%w_]")
        if pos then
          fline = ch.line
          fcol = pos
          break
        end
      end
      table.insert(cur_struct.fields, {
        name = decl.name,
        type = decl.type,
        struct_name = cur_struct.name,
        line = fline,
        col = fcol,
        path = filepath,
      })
    end
    struct_dim_buf = nil
  end

  local function current_block()
    return block_stack[#block_stack]
  end

  local function push_block(kind, lnum)
    local parent = current_block()
    local blk = new_block(kind, lnum, #lines, parent)
    table.insert(block_stack, blk)
    return blk
  end

  local function pop_block(lnum, expected_kind)
    if #block_stack <= 1 then return nil end
    local top = block_stack[#block_stack]
    if expected_kind and top.kind ~= expected_kind then
      -- Search downward in case an unclosed nested block sits above
      for i = #block_stack, 2, -1 do
        if block_stack[i].kind == expected_kind then
          while #block_stack >= i do
            local b = table.remove(block_stack)
            b.end_line = lnum
          end
          return top
        end
      end
      return nil
    end
    table.remove(block_stack)
    top.end_line = lnum
    return top
  end

  local function add_scope_var(name, ty, lnum, raw_line, kind)
    if not cur_scope then return end
    cur_scope.vars[name] = ty
    local blk = current_block()
    if blk then
      local col = raw_line and (raw_line:find("%f[%w_]" .. name .. "%f[^%w_]") or 1) or 1
      table.insert(blk.vars, {
        name = name,
        type = ty,
        line = lnum,
        col = col,
        path = filepath,
        kind = kind or "Dim",
      })
    end
  end

  for lnum, raw_line in ipairs(lines) do
    local trimmed = trim(raw_line)
    if trimmed:sub(1, 1) == "'" then
      table.insert(pending_doc, trim(trimmed:sub(2)))
    elseif trimmed == "" then
      pending_doc = {}
    else
      local code = trim(strip_comment(raw_line))
      local doc = #pending_doc > 0 and table.concat(pending_doc, "\n") or nil

      -- Include "..."
      local inc_path = code:match('^Include%s+"([^"]+)"')
      if inc_path then
        table.insert(entry.includes, { raw = inc_path, line = lnum })
        pending_doc = {}

      -- End Structure / End Enum / End Function / End Sub / End Test
      elseif code:match("^End%s+Structure%s*$") then
        flush_struct_dim()
        cur_struct = nil
        pending_doc = {}
      elseif code:match("^End%s+Enum%s*$") then
        cur_enum = nil
        pending_doc = {}
      elseif code:match("^End%s+Function%s*$") or code:match("^End%s+Sub%s*$") or code:match("^End%s+Test%s*$") then
        if cur_scope then
          while #block_stack > 0 do
            local b = table.remove(block_stack)
            b.end_line = lnum
          end
          while #open_withs > 0 do
            local w = table.remove(open_withs)
            w.end_line = lnum
          end
          cur_scope.end_line = lnum
          table.insert(entry.scopes, cur_scope)
          cur_scope = nil
        end
        pending_doc = {}

      -- Inside Structure: fields (supports multi-line trailing-comma Dim declarations)
      elseif cur_struct then
        if struct_dim_buf then
          struct_dim_buf.text = struct_dim_buf.text .. " " .. code
          table.insert(struct_dim_buf.chunks, { raw = raw_line, line = lnum })
          if not code:match(",%s*$") then
            flush_struct_dim()
          end
        else
          local fspec = code:match("^Dim%s+(.+)$")
          if fspec then
            struct_dim_buf = {
              text = fspec,
              chunks = { { raw = raw_line, line = lnum } },
            }
            if not fspec:match(",%s*$") then
              flush_struct_dim()
            end
          end
        end
        pending_doc = {}

      -- Inside Enum: members
      elseif cur_enum then
        local mname, mval = code:match("^([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.+)$")
        if not mname then
          mname = code:match("^([A-Za-z_][A-Za-z0-9_]*)%s*$")
        end
        if mname then
          local m = {
            name = mname,
            value = mval and trim(mval) or nil,
            enum_name = cur_enum.name,
            line = lnum,
            col = (raw_line:find(mname, 1, true) or 1),
            path = filepath,
          }
          table.insert(cur_enum.members, m)
        end
        pending_doc = {}

      -- Inside a function/sub/test scope: track nested blocks, With, For, Dim, Static
      elseif cur_scope then
        if code:match("^End%s+With%s*$") then
          if #open_withs > 0 then
            local w = table.remove(open_withs)
            w.end_line = lnum
          end
          pop_block(lnum, "with")
        elseif code:match("^End%s+If%s*$") then
          pop_block(lnum, "if")
        elseif code:match("^End%s+While%s*$") then
          pop_block(lnum, "while")
        elseif code:match("^End%s+For%s*$") or code:match("^Next%f[^%w_]") or code == "Next" then
          pop_block(lnum, "for")
        elseif code:match("^End%s+Match%s*$") or code:match("^End%s+Select%s*$") then
          if current_block() and current_block().kind == "case" then
            pop_block(lnum, "case")
          end
          pop_block(lnum, "match")
        elseif code:match("^ElseIf%s+.+%s+Then%s*$") or code:match("^Else%s*$") then
          if current_block() and current_block().kind == "if" then
            pop_block(lnum - 1, "if")
          end
          push_block("if", lnum)
        elseif code:match("^If%s+.+%s+Then%s*$") then
          push_block("if", lnum)
        elseif code:match("^While%s+") then
          push_block("while", lnum)
        elseif code:match("^For%s+") then
          push_block("for", lnum)
          local fvar = code:match("^For%s+([A-Za-z_][A-Za-z0-9_]*)%s*=")
          if fvar then
            add_scope_var(fvar, "Integer", lnum, raw_line, "For")
          end
        elseif code:match("^Match%s+") or code:match("^Select%s+Case%s+") then
          push_block("match", lnum)
        elseif code:match("^Case%s+") then
          -- Only push a lexical block for multi-line Case (not single-line `Case 0 Then Return b`)
          local is_single_line = code:match("%s+Then%s+.+$") ~= nil
          if not is_single_line then
            if current_block() and current_block().kind == "case" then
              pop_block(lnum - 1, "case")
            end
            push_block("case", lnum)
          end
        elseif code:match("^With%s+[^%(]") then
          local target = trim(code:sub(5))
          local wb = { start_line = lnum, end_line = #lines, target = target }
          table.insert(cur_scope.with_blocks, wb)
          table.insert(open_withs, wb)
          push_block("with", lnum)
        elseif code:match("^Volatile%s+Dim%s+") or code:match("^Dim%s+") then
          local dspec = code:gsub("^Volatile%s+", ""):gsub("^Dim%s+", "")
          for _, decl in ipairs(parse_grouped_decls(dspec)) do
            add_scope_var(decl.name, decl.type, lnum, raw_line, "Dim")
          end
        elseif code:match("^Public%s+Volatile%s+Static%s+")
            or code:match("^Private%s+Volatile%s+Static%s+")
            or code:match("^Public%s+Static%s+")
            or code:match("^Private%s+Static%s+")
            or code:match("^Volatile%s+Static%s+")
            or code:match("^Static%s+") then
          local sspec = code:gsub("^Public%s+", ""):gsub("^Private%s+", ""):gsub("^Volatile%s+", ""):gsub("^Static%s+", "")
          sspec = sspec:gsub("%s+At%s+.+$", "")
          for _, decl in ipairs(parse_grouped_decls(sspec)) do
            add_scope_var(decl.name, decl.type, lnum, raw_line, "Static")
          end
        end
        pending_doc = {}

      else
        -- Structure Name
        local vis, sname = code:match("^(Public)%s+Structure%s+([A-Za-z_][A-Za-z0-9_]*)")
        if not sname then vis, sname = code:match("^(Private)%s+Structure%s+([A-Za-z_][A-Za-z0-9_]*)") end
        if not sname then sname = code:match("^Structure%s+([A-Za-z_][A-Za-z0-9_]*)") end
        if sname then
          cur_struct = {
            name = sname,
            kind = "Structure",
            is_private = (vis == "Private"),
            line = lnum,
            col = (raw_line:find(sname, 1, true) or 1),
            path = filepath,
            doc = doc,
            fields = {},
          }
          struct_dim_buf = nil
          entry.structs[sname] = cur_struct
          table.insert(entry.symbols, cur_struct)
          pending_doc = {}

        -- Enum Name
        else
          local evis, ename = code:match("^(Public)%s+Enum%s+([A-Za-z_][A-Za-z0-9_]*)")
          if not ename then evis, ename = code:match("^(Private)%s+Enum%s+([A-Za-z_][A-Za-z0-9_]*)") end
          if not ename then ename = code:match("^Enum%s+([A-Za-z_][A-Za-z0-9_]*)") end
          if ename then
            cur_enum = {
              name = ename,
              kind = "Enum",
              is_private = (evis == "Private"),
              line = lnum,
              col = (raw_line:find(ename, 1, true) or 1),
              path = filepath,
              doc = doc,
              members = {},
            }
            entry.enums[ename] = cur_enum
            table.insert(entry.symbols, cur_enum)
            pending_doc = {}

          -- Declare Function / Sub
          elseif code:match("^Public%s+Declare%s+") or code:match("^Private%s+Declare%s+") or code:match("^Declare%s+") then
            local dvis = code:match("^(Private)%s+")
            local rest = code:gsub("^Public%s+", ""):gsub("^Private%s+", ""):gsub("^Declare%s+", "")
            local dkind, dname, dparams, dret = rest:match("^(Function)%s+([A-Za-z_][A-Za-z0-9_]*)%s*%((.*)%)%s*As%s+([A-Za-z_][A-Za-z0-9_%(%)]*)")
            if not dname then
              dkind, dname, dparams = rest:match("^(Sub)%s+([A-Za-z_][A-Za-z0-9_]*)%s*%((.*)%)")
            end
            if not dname then
              dkind, dname, dparams = rest:match("^(Function)%s+([A-Za-z_][A-Za-z0-9_]*)%s*%((.*)%)")
            end
            if dname then
              local fn = {
                name = dname,
                kind = "Declare " .. dkind,
                params = dparams or "",
                param_list = parse_grouped_decls(dparams or ""),
                ret = dret or (dkind == "Sub" and "Void" or "Any"),
                sig = code,
                is_private = (dvis == "Private"),
                line = lnum,
                col = (raw_line:find(dname, 1, true) or 1),
                path = filepath,
                doc = doc,
              }
              entry.functions[dname] = fn
              table.insert(entry.symbols, fn)
            end
            pending_doc = {}

          -- Function / Sub (with optional Public/Private + Async)
          elseif code:match("^Public%s+Async%s+Function%s+")
              or code:match("^Private%s+Async%s+Function%s+")
              or code:match("^Async%s+Function%s+")
              or code:match("^Public%s+Function%s+")
              or code:match("^Private%s+Function%s+")
              or code:match("^Function%s+")
              or code:match("^Public%s+Async%s+Sub%s+")
              or code:match("^Private%s+Async%s+Sub%s+")
              or code:match("^Async%s+Sub%s+")
              or code:match("^Public%s+Sub%s+")
              or code:match("^Private%s+Sub%s+")
              or code:match("^Sub%s+") then
            local fvis = code:match("^(Private)%s+")
            local is_async = code:find("Async%s+") ~= nil
            local rest = code:gsub("^Public%s+", ""):gsub("^Private%s+", ""):gsub("^Async%s+", "")
            local fkind, fname, fparams, fret = rest:match("^(Function)%s+([A-Za-z_][A-Za-z0-9_]*)%s*%((.*)%)%s*As%s+([A-Za-z_][A-Za-z0-9_%(%)]*)")
            if not fname then
              fkind, fname, fparams = rest:match("^(Sub)%s+([A-Za-z_][A-Za-z0-9_]*)%s*%((.*)%)")
            end
            if not fname then
              fkind, fname, fparams = rest:match("^(Function)%s+([A-Za-z_][A-Za-z0-9_]*)%s*%((.*)%)")
            end
            if fname then
              local plist = parse_grouped_decls(fparams or "")
              local fn = {
                name = fname,
                kind = fkind,
                params = fparams or "",
                param_list = plist,
                ret = fret or (fkind == "Sub" and "Void" or "Any"),
                sig = code,
                is_private = (fvis == "Private"),
                is_async = is_async,
                line = lnum,
                col = (raw_line:find(fname, 1, true) or 1),
                path = filepath,
                doc = doc,
              }
              entry.functions[fname] = fn
              table.insert(entry.symbols, fn)
              local root_blk = new_block("fn", lnum, #lines, nil)
              cur_scope = { start_line = lnum, end_line = #lines, vars = {}, root_block = root_blk, with_blocks = {} }
              block_stack = { root_blk }
              open_withs = {}
              for _, p in ipairs(plist) do
                add_scope_var(p.name, p.type, lnum, raw_line, "Param")
              end
            end
            pending_doc = {}

          -- Test "name"
          elseif code:match('^Test%s+"') then
            local root_blk = new_block("test", lnum, #lines, nil)
            cur_scope = { start_line = lnum, end_line = #lines, vars = {}, root_block = root_blk, with_blocks = {} }
            block_stack = { root_blk }
            open_withs = {}
            pending_doc = {}

          -- Top-level Static globals
          elseif code:match("^Public%s+Volatile%s+Static%s+")
              or code:match("^Private%s+Volatile%s+Static%s+")
              or code:match("^Public%s+Static%s+")
              or code:match("^Private%s+Static%s+")
              or code:match("^Volatile%s+Static%s+")
              or code:match("^Static%s+") then
            local svis = code:match("^(Private)%s+")
            local sspec = code:gsub("^Public%s+", ""):gsub("^Private%s+", ""):gsub("^Volatile%s+", ""):gsub("^Static%s+", "")
            sspec = sspec:gsub("%s+At%s+.+$", "")
            for _, decl in ipairs(parse_grouped_decls(sspec)) do
              local st = {
                name = decl.name,
                kind = "Static",
                type = decl.type,
                is_private = (svis == "Private"),
                line = lnum,
                col = (raw_line:find(decl.name, 1, true) or 1),
                path = filepath,
                doc = doc,
              }
              entry.statics[decl.name] = st
              table.insert(entry.symbols, st)
            end
            pending_doc = {}

          else
            pending_doc = {}
          end
        end
      end
    end
  end

  flush_struct_dim()
  if cur_scope then
    while #block_stack > 0 do
      local b = table.remove(block_stack)
      b.end_line = #lines
    end
    cur_scope.end_line = #lines
    table.insert(entry.scopes, cur_scope)
  end

  return entry
end

function M.find_project_root(filepath)
  local dir = vim.fs.dirname(filepath)
  local found = vim.fs.find({ "verbose.toml", ".git", "makefile", "Makefile" }, {
    upward = true,
    path = dir,
  })
  if found and #found > 0 then
    return vim.fs.dirname(found[1])
  end
  return dir
end

function M.search_dirs(filepath)
  local dirs = {}
  local seen = {}
  local function add(d)
    if d and d ~= "" then
      local nd = norm_path(d)
      if not seen[nd] and vim.fn.isdirectory(nd) == 1 then
        seen[nd] = true
        table.insert(dirs, nd)
      end
    end
  end

  add(vim.fs.dirname(filepath))
  local root = M.find_project_root(filepath)
  add(root)
  for _, rel in ipairs(config.options.include_paths or {}) do
    if rel:sub(1, 1) == "/" or rel:match("^[A-Za-z]:") then
      add(rel)
    else
      add(vim.fs.joinpath(root, rel))
    end
  end

  -- Also honor verbose.toml include_dir if present
  local toml = vim.fs.joinpath(root, "verbose.toml")
  if vim.fn.filereadable(toml) == 1 then
    for _, line in ipairs(vim.fn.readfile(toml)) do
      local inc = line:match('^include_dir%s*=%s*"([^"]+)"')
      if inc then
        add(vim.fs.joinpath(root, inc))
      end
    end
  end

  return dirs
end

function M.resolve_include(from_file, raw_inc)
  local norm_inc = raw_inc:gsub("\\", "/")
  for _, d in ipairs(M.search_dirs(from_file)) do
    local candidate = norm_path(vim.fs.joinpath(d, norm_inc))
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

function M.index_file(filepath, override_lines)
  local abs = norm_path(filepath)
  if override_lines then
    local entry = M.parse_lines(override_lines, abs)
    M.cache[abs] = { mtime = -1, entry = entry }
    return entry
  end

  local st = vim.uv.fs_stat(abs)
  if not st then
    return nil
  end
  local mtime = (st.mtime.sec or 0) * 1000000000 + (st.mtime.nsec or 0)
  local cached = M.cache[abs]
  if cached and cached.mtime == mtime then
    return cached.entry
  end

  local ok, lines = pcall(vim.fn.readfile, abs)
  if not ok or not lines then
    return nil
  end
  local entry = M.parse_lines(lines, abs)
  M.cache[abs] = { mtime = mtime, entry = entry }
  return entry
end

-- Build aggregated workspace index for a root buffer + all transitively Included files
function M.collect_graph(filepath, override_lines)
  local root_abs = norm_path(filepath)
  local visited = {}
  local result = {
    root = nil,
    files = {},       -- ordered list of entries
    structs = {},     -- visible structs
    enums = {},       -- visible enums
    enum_members = {},-- unqualified member name -> { member, count }
    functions = {},   -- visible functions / subs / declares
    statics = {},     -- visible statics
  }

  local function merge(entry, is_root)
    table.insert(result.files, entry)
    for k, s in pairs(entry.structs) do
      if is_root or not s.is_private then
        result.structs[k] = s
      end
    end
    for k, e in pairs(entry.enums) do
      if is_root or not e.is_private then
        result.enums[k] = e
        for _, m in ipairs(e.members) do
          local slot = result.enum_members[m.name]
          if slot then
            slot.count = slot.count + 1
          else
            result.enum_members[m.name] = { member = m, count = 1 }
          end
        end
      end
    end
    for k, f in pairs(entry.functions) do
      if is_root or not f.is_private then
        result.functions[k] = f
      end
    end
    for k, st in pairs(entry.statics) do
      if is_root or not st.is_private then
        result.statics[k] = st
      end
    end
  end

  local function walk(path, is_root, lines_opt)
    local abs = norm_path(path)
    if visited[abs] then return end
    visited[abs] = true

    local entry = M.index_file(abs, lines_opt)
    if not entry then return end
    if is_root then result.root = entry end

    -- Index included files first so local definitions override cleanly
    for _, inc in ipairs(entry.includes) do
      local target = M.resolve_include(abs, inc.raw)
      if target then
        walk(target, false, nil)
      end
    end
    merge(entry, is_root)
  end

  walk(root_abs, true, override_lines)
  return result
end

function M.clear_cache()
  M.cache = {}
end

function M.cache_stats()
  local n = 0
  local files = {}
  for p, _ in pairs(M.cache) do
    n = n + 1
    table.insert(files, p)
  end
  table.sort(files)
  return n, files
end

return M
