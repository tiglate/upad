# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

UnbloatedPad (`upad`) — a Linux GTK4 + libadwaita Notepad-style text editor,
written **entirely in hand-written x86-64 assembly** (NASM), with no C glue
code. It's a Linux port of TinyRetroPad (a Windows/MASM project); this repo
is just the Linux port, not the monorepo it was extracted from — ignore any
stray references elsewhere to a `linux/` subdirectory or a top-level
`../README.md`, they don't apply here. Everything lives at the repo root.

GCC is used only as the link driver (to get a normal glibc CRT startup —
`_start`, TLS, malloc, pthreads — that GTK/GLib themselves require). Every
line of actual editor logic calls straight into the `libgtk-4` /
`libadwaita-1` / `libgio-2.0` / `libgobject-2.0` C ABI from assembly.

## Build commands

```bash
make          # -> ./upad
make run      # build (if needed) and launch it
make clean    # remove build/ and the upad binary
make release  # clean rebuild, then strip debug info -> a ~58% smaller ./upad
```

Each `src/*.asm` is assembled independently (`nasm -f elf64 -g -F dwarf -I src/`)
into `build/*.o`, then linked in one step against
`$(pkg-config --libs gtk4 libadwaita-1)`. There is no test suite — validate
changes by building and by running `./upad` (and `./upad somefile.txt`)
manually.

The version number lives in one place, the `.version` file at the repo
root — never hardcoded in the Makefile or in any `.asm` file. The Makefile
reads it for `DEB_VERSION` and generates `build/version.inc` from it (a
single `version_str db "...", 0`), which `src/about.asm` `%include`s for
the About dialog's version field. To bump the version, edit `.version`
only; `build/version.inc` is regenerated automatically and gitignored
(it's derived, like everything else under `build/`).

Requires: `nasm`, `gcc`, `pkg-config`, `libgtk-4-dev`, `libadwaita-1-dev`
(>= 1.5, for GTK 4.10-era Font/Find/Replace/Go To dialog APIs). If
`pkg-config` can't find `gtk4`/`libadwaita-1` even though installed, point
`PKG_CONFIG_PATH` at wherever `find /usr/lib -name 'gtk4.pc'` turns up.

To debug a build failure of the form `ld: relocation ... in read-only
section '.text'` / `undefined reference`: a symbol called with `ICALL` (see
below) isn't declared `global` in the file that defines it — `ICALL` is for
this program's own cross-file functions (no PLT), `CCALL` is for external
GTK/GLib/libadwaita/libc functions (via PLT).

## Architecture

One file per feature area (no byte-count pressure keeping things crammed
together, unlike the original):

| File | Owns |
|---|---|
| `main.asm` | Process entry point (`main`), `AdwApplication` setup, `activate`/`open` signal wiring |
| `window.asm` | Builds the window/menu bar/text view/status bar; dispatches `activate` and `open` (command-line file) signals |
| `menu.asm` | The File/Edit/Format/View/Help `GMenu` model, wrapped in a `GtkPopoverMenuBar` |
| `actions.asm` | Registers every `GAction` (`win.*` / `app.*`) and points it at its handler |
| `fileio.asm` | New/Open/Save/Save As: `GtkFileDialog` for the picker, raw `open`/`read`/`write`/`close` for the bytes |
| `errdlg.asm` | `report_error`/`report_file_error`: a `GtkAlertDialog` for the user, `g_log` (journal/stderr) for later examination — called from `fileio.asm` and `printing.asm` |
| `printing.asm` | File > Page Setup.../Print..., via `GtkPageSetup`/`GtkPrintSettings` and `GtkPrintOperation`'s begin-print/draw-page/end-print signals (Pango layout pagination + cairo drawing) |
| `editops.asm` | Undo/Cut/Copy/Paste/Delete/Select All (GTK's own built-in text widget actions) + Time/Date |
| `finddlg.asm` | Find, Replace, and Go To Line dialogs and the search logic behind them |
| `format.asm` | Word Wrap, Font (via `GtkFontDialog`, applied as hand-built CSS), Dark Mode |
| `statusbar.asm` | The "Ln X, Col Y" status bar |
| `linenum.asm` | View > Line Numbers (on by default): a `GtkDrawingArea` dropped into the text view's own gutter (`gtk_text_view_set_gutter`), hand-drawn per visible line with Pango/cairo |
| `unsaved.asm` | Tracks unsaved changes; interposes a Save/Discard/Cancel prompt in front of New/Open/Quit/window-close |
| `about.asm` | Help > About, via `AdwAboutDialog` (version field from generated `build/version.inc`, see above) |
| `accels.asm` | Keyboard accelerators (`Ctrl+N`, `F3`, ...) for actions with no built-in GTK binding |
| `consts.inc` | Every enum/flag/struct-layout constant, each sourced from the installed system headers (comment above each block names the header) |
| `extern.inc` | `extern` declarations for every GTK/GLib/libadwaita/libc function called from assembly |
| `callconv.inc` | The calling-convention discipline every function follows (below) |

Long-lived widget/state pointers (`g_app`, `g_window`, `g_textview`,
`g_buffer`, `g_scrolled`, `g_box`, `g_current_path`, ...) live in `.bss`
globals declared in the file that owns them and `extern`'d wherever else
they're read — never passed around as function args. The window and its
children are built lazily in `window.asm`'s `ensure_main_window`, the first
time either `on_activate` or `on_open_signal` fires (both can be first;
`ensure_main_window` is idempotent).

### Calling convention

System V AMD64 ABI throughout. Every function's prologue is
`push rbp` / `mov rbp, rsp` / `[sub rsp, N]` with `N` always a multiple of
16, keeping `rsp` 16-aligned before every `call`. Two macros in
`callconv.inc` wrap `call`:

- **`CCALL`** — external functions (GTK/GLib/libadwaita/libc), via PLT
  (`call foo wrt ..plt` — required because the program links as a PIE),
  zeroing `AL` first (the "0 vector registers used" variadic-call contract;
  no float/SSE args are ever passed to GTK/GLib/Adwaita here).
- **`ICALL`** — this program's own functions defined in another `.asm`
  file (no PLT indirection needed).

Values that must survive a nested `call` are always stashed in a `g_*`
`.bss` global or a genuine `[rbp-N]` stack slot immediately — never left in
a caller-saved register (`rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8`-`r11`),
since any call is free to clobber those. Callee-saved registers (`r12`+)
are used, with explicit push/pop, when a value must survive across a
larger stretch of code within one function (see `main.asm`'s use of
`r12`/`r13` for `argc`/`argv`).

### Struct layouts

`GtkTextIter` (80 bytes, opaque) and `GActionEntry` (64 bytes: 5
pointer-sized fields + padding) are stack-allocated directly from assembly
in a few places. Their layouts in `consts.inc` were verified with
`sizeof`/`offsetof` against real installed headers, not guessed — if
building against a GTK/GLib old/new enough that either struct changed,
re-verify with a small C program before trusting these constants.

### Naming conventions to follow

- Signal handlers: `on_<signal>` (e.g. `on_activate`, `on_dark_mode_activate`).
- One-time lazy builders: `ensure_<thing>` (idempotent, check-then-build).
- Globals: `g_<name>` in `.bss`, declared `global` in their owning file,
  `extern`'d elsewhere.
- Every `.asm` file starts with a comment explaining what it owns and why;
  every non-trivial instruction block gets an inline `;` comment explaining
  *why*, not just what — match this density when adding code.
- `consts.inc` entries always cite the system header they were checked
  against; do the same for any new constant.

## Known limitations (don't "fix" without being asked)

- Printing (`printing.asm`) always uses the last Format > Font... pick (or
  "Monospace 11" if none) for the whole document — there's no per-print
  font/size override independent of the on-screen font, and no
  header/footer/page-number support.
- A short `write()` (fewer bytes written than the buffer's length) is still
  treated as success in `write_buffer_to_file` — only a hard failure
  (return value < 0) goes through `errdlg.asm`'s error dialog/log path.
- Forcing *light* mode isn't guaranteed to override a desktop theme that's
  itself always-dark (see the comment above `on_dark_mode_activate` in
  `format.asm`).
- Replace All + an unsaved-changes Save prompt on a never-saved document:
  the Save As it triggers is asynchronous, so the original New/Open/Quit
  action is dropped rather than chained after it — documented, not a bug
  to silently patch over.
- The line-numbers gutter (`linenum.asm`) draws its digits in a fixed
  mid-gray, not a theme-aware color — readable in both light and dark mode
  without `linenum.asm` needing to track `format.asm`'s dark-mode state too.
