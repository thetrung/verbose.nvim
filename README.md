# verbose.nvim

Full-featured **Neovim** plugin for **[VerBose-Lang](https://github.com/thetrung/verbose-lang)** (`v0.6.0+`):

- **Tree-sitter Grammar & Queries** (`tree-sitter-verbose/` + `queries/verbose/{highlights,locals,folds,indents}.scm`) with pre-generated `parser.c` (compiles in <1s with `clang`/`cc` — no Node or `tree-sitter-cli` required) plus a Vim regex syntax fallback (`syntax/verbose.vim`).
- **Zero-Dependency In-Process LSP (`verbose_ls`)** with **recursive `Include`-graph caching** (mtime-invalidated across local files, `src/`, `std/`, `.vpkg/include/`, and `verbose.toml`):
  - Context-aware **auto-completion** (works with `blink.cmp`, `nvim-cmp`, LazyVim, and built-in `omnifunc`):
    - Nested struct `.field` chains (`ship.tf.pos.`, `particles(i).`, `(Await job).tf.pos.`)
    - Nested `With <lvalue>` blocks (`With .tf` → `With .pos`, `.tf.pos.`) and nested inline `Type With ( ... )` initializers
    - Lexical block scoping (`If`/`Else`/`For`/`While`/`Match`) with shadowing & `For` loop variables
    - `Enum.` member & unqualified enum member completion
    - `Include "..."` file path completion
    - Included functions, subs, C `Declare`s, structs, enums, statics, locals, types, builtins & keywords
  - **Go-to-definition (`gd`)** & **Hover (`K`)** across transitively `Include`d files, nested struct fields (`ship.tf.pos.z`, `.x` in `With`), locals, and `Include "..."` paths
  - **Document symbols** outline & **Signature help** parameter hints
  - **Live Compiler Diagnostics** via `verbose --emit-only` on open & save
- **Built-in VerBose Compiler Installer (`:VerboseInstall`)**: Downloads the latest platform release binary directly from [thetrung/verbose-lang Releases](https://github.com/thetrung/verbose-lang/releases/latest) (Linux x86-64/arm64, macOS arm64, Windows x86-64) and compiles the Tree-sitter parser.

## Installation

### lazy.nvim / LazyVim

```lua
{
  "thetrung/verbose.nvim",
  ft = { "verbose" },
  build = "bash scripts/build_parser.sh",
  opts = {
    -- Automatically download latest `verbose` binary if not found on PATH:
    auto_install_compiler = true,
    -- Extra Include search roots (relative to project root or absolute):
    include_paths = { ".", "src", "std", ".vpkg/include" },
  },
}
```

Then inside Neovim, run `:VerboseInstall` at any time to fetch/upgrade the latest `verbose` compiler binary and rebuild the Tree-sitter parser.

## Commands

| Command | Description |
| :--- | :--- |
| `:VerboseInstall [tag]` | Download latest (or specified tag, e.g. `v0.6.0`) `verbose` binary & build Tree-sitter parser |
| `:VerboseBuildParser` | Compile bundled `tree-sitter-verbose/src/parser.c` into `parser/verbose.so` |
| `:VerboseRun [args...]` | Compile and run the current `.vb` file in a split terminal |
| `:VerboseTest [path]` | Run `verbose test` on the current file or specified directory |
| `:VerboseCheck` | Trigger semantic type-analyzer diagnostics on the current buffer |
| `:VerboseCacheInfo` | List all currently cached files in the Include dependency graph |
| `:VerboseCacheClear` | Clear the Include symbol cache |

## Testing

```bash
bash scripts/build_parser.sh
nvim --headless -u NONE -l tests/run_tests.lua
```
