# Copilot instructions for this repository (UnbloatedPad / upad)

Purpose
- Short, focused guidance for Copilot-style assistants operating in this repo. Use README.md and CLAUDE.md for deeper context; this file highlights the practical, repo-specific commands, architecture, and conventions an assistant must follow.

Build / test / lint commands
- Full build: `make`
- Build & run: `make run` (builds if needed, then launches ./upad)
- Clean: `make clean`
- Release (strip debug info): `make release`
- Debian package: `make deb`
- Install / uninstall: `sudo make install` / `sudo make uninstall`

Notes:
- There is no automated test suite. To validate a change, run `make` (incremental) then `./upad` or `make run` to exercise behavior manually.
- Each `src/*.asm` is assembled with NASM into `build/*.o` and then linked via `gcc` against `$(pkg-config --libs gtk4 libadwaita-1)`.
- If pkg-config cannot find GTK/libadwaita, locate the .pc files (e.g. `find /usr/lib -name 'gtk4.pc'`) and set `PKG_CONFIG_PATH` accordingly.

High-level architecture (big picture)
- One assembly file per feature area. Major files and responsibilities:
  - `main.asm` — process entry, AdwApplication setup, activate/open wiring
  - `window.asm` — window, menubar, text view, status bar
  - `menu.asm` / `actions.asm` — GMenu model and GActions
  - `fileio.asm` / `errdlg.asm` — open/save and error dialogs/logging
  - `printing.asm` — PageSetup/PrintOperation (Pango + cairo)
  - `editops.asm`, `finddlg.asm`, `format.asm`, `statusbar.asm`, `linenum.asm`, `unsaved.asm`, `about.asm`, `accels.asm`
- Build pipeline: `nasm -f elf64 -g -F dwarf -I src` → `build/*.o` → link with `gcc` (PIE) using pkg-config libs.
- Single source of truth for version: `.version` at repo root. Makefile reads this and generates `build/version.inc` (used by `about.asm`).

Key conventions (must-follow)
- Calling conventions / macros:
  - System V AMD64 ABI. Keep `rsp` 16-aligned before every `call`.
  - `CCALL` for external (GTK/GLib/libadwaita/libc) calls: call via PLT; zero `al` first for the variadic-calls contract.
  - `ICALL` for internal cross-file calls (no PLT). If an `ICALL` target is undefined or not `global`, the linker will produce relocation/undefined-reference errors.
- Globals and state:
  - Long-lived widget/state pointers live in `.bss` globals named `g_<name>` in the owning file and are `extern`'d where used. Do not pass these as function args unless temporary.
  - Values that must survive a nested call must be placed in `.bss` globals or in `[rbp-N]` stack slots immediately.
- File & symbol naming:
  - Signal handlers: `on_<signal>` (e.g., `on_activate`).
  - One-time lazy builders: `ensure_<thing>` (idempotent).
  - `consts.inc` entries must cite the system header they were verified against.
- Struct layouts:
  - `GtkTextIter` and `GActionEntry` are stack-allocated with fixed sizes verified against installed headers. If building against different GTK/GLib versions, re-verify with a small C program.
- Versioning & releases:
  - `.version` is authoritative. GitHub Actions (`.github/workflows/publish-deb.yml`) runs `make deb` on published releases and uses `.version` (not the release tag name) to set the package version.

Repo-specific editing rules for assistants
- Make minimal, surgical edits. Avoid changing unrelated files.
- If adding a function that will be ICALL'ed from another file, mark it `global` in the defining .asm file.
- When adding/adjusting constants in `consts.inc`, include the system header reference and a short verification note.
- Validate changes by running `make` and then `./upad` (or `make run`). Building locally is required — there are no automated unit tests.

Other assistant configs
- `CLAUDE.md` exists and contains extended context about architecture, calling conventions, and limitations. Refer to it for detailed guidance.
- There is a local `.claude/settings.local.json` file present; do not publish secrets from local settings.

Commit/PR conventions
- When an assistant creates commits on behalf of humans, include the following Co-authored-by trailer in commit messages unless instructed otherwise:
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`

Where to look next
- README.md and CLAUDE.md (they contain authoritative architecture and build notes).
- `src/callconv.inc`, `src/consts.inc`, and `src/extern.inc` for low-level calling/struct details.

If anything here should be expanded or a specific workflow (packaging, cross-build, debugging with gdb) added, say which area to cover and examples to include.
