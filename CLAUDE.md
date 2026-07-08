# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

UnbloatedPad (`upad`) — a Linux GTK4 + libadwaita Notepad-style text editor,
written **entirely in hand-written x86-64 assembly** (NASM), with no C glue
code. It's loosely inspired by TinyRetroPad (a Windows/MASM project) — same
"no C glue code" spirit and Notepad feature set, but a from-scratch rewrite
targeting a completely different platform/API, sharing no actual code with
it beyond a few literal menu-label strings. This repo is standalone, not
part of the monorepo TinyRetroPad itself lives in — ignore any stray
references elsewhere to a `linux/` subdirectory or a top-level
`../README.md`, they don't apply here. Everything lives at the repo root.

GCC is used only as the link driver (to get a normal glibc CRT startup —
`_start`, TLS, malloc, pthreads — that GTK/GLib themselves require). Every
line of actual editor logic calls straight into the `libgtk-4` /
`libadwaita-1` / `libgio-2.0` / `libgobject-2.0` / `libuchardet` C ABI
from assembly.

## Build commands

```bash
make          # -> ./upad
make run      # build (if needed) and launch it
make clean    # remove build/ and the upad binary
make release  # clean rebuild, then strip debug info -> a ~58% smaller ./upad
```

Each `src/*.asm` is assembled independently (`nasm -f elf64 -g -F dwarf -I src/`)
into `build/*.o`, then linked in one step against
`$(pkg-config --libs gtk4 libadwaita-1 uchardet)`. There is no test suite —
validate changes by building and by running `./upad` (and `./upad somefile.txt`)
manually.

The version number lives in one place, the `.version` file at the repo
root — never hardcoded in the Makefile or in any `.asm` file. The Makefile
reads it for `DEB_VERSION` and generates `build/version.inc` from it (a
single `version_str db "...", 0`), which `src/about.asm` `%include`s for
the About dialog's version field. To bump the version, edit `.version`
only; `build/version.inc` is regenerated automatically and gitignored
(it's derived, like everything else under `build/`).

`.github/workflows/publish-deb.yml` fires on `release: published` (never
on drafts, edits, or plain pushes/tags): it runs `make deb` — which reads
`.version` the same way a local build would, not the release's own tag
name — and uploads the resulting `upad_<version>_amd64.deb` as an asset
on that release via `gh release upload`.

Requires: `nasm`, `gcc`, `pkg-config`, `libgtk-4-dev`, `libadwaita-1-dev`
(>= 1.5, for GTK 4.10-era Font/Find/Replace/Go To dialog APIs), `libuchardet-dev`
(charset detection, `encoding.asm`), and the `gettext` package (`msgfmt`,
build-time only -- `xgettext`/`msgcat` are only needed for `make pot`, see
below; there's no new *runtime* link dependency, since `setlocale`/
`bindtextdomain`/`gettext` etc. are all built into glibc directly). If
`pkg-config` can't find `gtk4`/`libadwaita-1`/`uchardet` even though
installed, point `PKG_CONFIG_PATH` at wherever `find /usr/lib -name
'gtk4.pc'` turns up.

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
| `encoding.asm` | Transcodes non-UTF-8 files to UTF-8 on load via `g_convert` -- UTF-16 (LE/BE) detected by its byte-order mark; otherwise, if not valid UTF-8, `uchardet` guesses the charset (falling back to Windows-1252 if it has no verdict or the guess doesn't decode); on Save/Save As, asks once (`AdwAlertDialog`) whether to keep writing the original encoding or convert to UTF-8 |
| `errdlg.asm` | `report_error`/`report_file_error`: a `GtkAlertDialog` for the user, `g_log` (journal/stderr) for later examination — called from `fileio.asm`, `printing.asm`, and `encoding.asm` |
| `printing.asm` | File > Page Setup.../Print..., via `GtkPageSetup`/`GtkPrintSettings` and `GtkPrintOperation`'s begin-print/draw-page/end-print signals (Pango layout pagination + cairo drawing) |
| `editops.asm` | Undo/Cut/Copy/Paste/Delete/Select All (GTK's own built-in text widget actions) + Time/Date |
| `finddlg.asm` | Find, Replace, and Go To Line dialogs and the search logic behind them |
| `format.asm` | Word Wrap, Font (via `GtkFontDialog`, applied as hand-built CSS), Dark Mode |
| `statusbar.asm` | The "Ln X, Col Y" status bar |
| `linenum.asm` | View > Line Numbers (on by default): a `GtkDrawingArea` dropped into the text view's own gutter (`gtk_text_view_set_gutter`), hand-drawn per visible line with Pango/cairo |
| `unsaved.asm` | Tracks unsaved changes; interposes a Save/Discard/Cancel prompt in front of New/Open/Quit/window-close |
| `about.asm` | Help > About, via `AdwAboutDialog` (version field from generated `build/version.inc`, see above) |
| `accels.asm` | Keyboard accelerators (`Ctrl+N`, `F3`, ...) for actions with no built-in GTK binding |
| `i18n.asm` | One-time GNU gettext startup setup (`setup_i18n`, called first in `main()`) -- see "Internationalization (i18n)" below |
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

## Internationalization (i18n)

Built on GNU gettext + GLib, following the system locale (`$LANG`/
`$LANGUAGE`) -- there's no in-app language switcher/settings subsystem.
Test a specific language with `LANGUAGE=pt_BR ./upad` (also `es`, `it`,
`pt_PT`, `fr`, `de`, `nl`, `pl`, `hr`, `ro`, `el`, `is`, `nb`, `sv`, `fi`,
`ru`, `uk`, `he`, `ar`, `ja`, `ko`, `hi`, `zh_CN`) without needing that
locale actually installed on the system.

- Every user-visible string in `src/*.asm` is a plain `db "...", 0` marked
  with a trailing `; i18n:` comment (optionally followed by a note, e.g.
  `; i18n: proper noun, deliberately NOT translated`); its use site wraps
  it with `CCALL gettext` before handing it to whatever GTK/GLib/
  libadwaita setter consumes it. Proper nouns (app name, developer name,
  URLs) are deliberately left unmarked/untranslated.
- `gettext(...)` clobbers every caller-saved register (SysV convention),
  so its call always runs *before* the other arguments of the call it's
  feeding are loaded into their registers -- reusing an already-dead
  stack slot to stash its result across a second `gettext` call where
  more than one string needs translating for the same GTK/libadwaita call
  (see e.g. `unsaved.asm`'s `request_close` or `encoding.asm`'s
  `ensure_encoding_resolved`).
- `ui/*.ui`'s own translatable strings just need `translatable="yes"` on
  the property/attribute (GtkBuilder translates them automatically
  against the domain `i18n.asm`'s `textdomain()` call sets up -- no
  per-`GtkBuilder` call needed).
- `.mo` catalogs are plain filesystem files, not GResource-embedded (glibc's
  `gettext()` has no GResource awareness) -- same precedent as `icons/`,
  not the `ui/`-GResource one. `src/i18n.asm`'s `setup_i18n` binds the
  `"upad"` domain to `<exe_dir>/locale` for an uninstalled dev build
  (`make && ./upad`, generated at `locale/<lang>/LC_MESSAGES/upad.mo`,
  gitignored) but skips `bindtextdomain` entirely for an installed build,
  letting glibc fall back to its own compiled-in default
  (`$(PREFIX)/share/locale/...`, populated by `make install`/the `.deb`).
- xgettext has no NASM support, so `scripts/extract-asm-strings.py` scans
  `src/*.asm` by hand for the `; i18n:` convention above and emits a
  `.pot` fragment; `make pot` merges that with `xgettext
  --language=Glade`'s own extraction from `ui/*.ui` (which handles both
  `<property translatable="yes">` and GMenu `<attribute
  translatable="yes">` natively) via `msgcat`, writing `po/upad.pot`.
  After changing/adding a translatable string: `make pot`, then
  `msgmerge --update po/<lang>.po po/upad.pot` for each `po/*.po` file
  (one per `LINGUAS` entry in the Makefile), then fill in any new/fuzzy
  entries by hand.

## Known limitations (don't "fix" without being asked)

- `encoding.asm` recognizes UTF-16 via its byte-order mark, and otherwise
  (on a UTF-8 validation failure with no UTF-16 BOM) uses `uchardet` to
  guess the charset, falling back to Windows-1252 as a last resort if
  `uchardet` has no confident verdict or its guess doesn't actually
  decode. `uchardet` is a statistical sniffer, not a certainty, so a
  short or ambiguous legacy file can still occasionally be misdetected
  (same category of imperfection any charset sniffer ships with — see
  that file's own header comment for the full fallback chain). Also, the
  encoding choice on Save is asked at most once per document per session
  (remembered after that) — there's no menu item to revisit it later
  without re-opening the file. UTF-32 (also BOM-detectable) isn't handled
  either.
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
