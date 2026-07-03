# UnbloatedPad (Linux / GTK4 + libadwaita)

A Linux port of [TinyRetroPad](../README.md), written the same way the
original Windows version is: **entirely in hand-written assembly**, with
no C glue code anywhere. Unlike the original, this port doesn't chase a
minimal byte count — the goal here is a correct, readable, maintainable
GTK4 application, calling straight into the `libgtk-4` / `libadwaita-1` /
`libgio-2.0` / `libgobject-2.0` C ABI from x86-64 assembly.

## Author

This Linux port (renamed **UnbloatedPad**, distinct from the Windows
**TinyRetroPad** it's ported from) was created by **Tiglate Pileser III**
(`tiglate`), written with **Claude (Anthropic)** acting as the assembly
author under his direction. The original Windows/MASM TinyRetroPad this
is ported from is by Dave Plummer and Matt Power — see the top-level
[README](../README.md) for that project's own credits.

## Requirements

- **NASM** (`nasm`) — the assembler
- **GCC** (`gcc`) — used only as the link driver, so the program gets a
  normal glibc CRT startup (`_start`, TLS, etc.) for free. GTK/GLib
  themselves need a fully initialized libc (malloc, pthreads, locale), so
  there's no benefit to hand-rolling that; every line of *editor logic*
  above that point is still assembly.
- **`pkg-config`**
- **GTK4 development headers** (`libgtk-4-dev` on Debian/Ubuntu)
- **libadwaita development headers**, **1.5 or newer** (`libadwaita-1-dev`)
  — the Font/Find/Replace/Go To dialogs and Help > About use APIs
  introduced in GTK 4.10 and libadwaita 1.5.

On Debian/Ubuntu/Zorin:

```bash
sudo apt-get install nasm build-essential pkg-config libgtk-4-dev libadwaita-1-dev
```

## Build

```bash
cd linux
make          # -> ./upad
make run      # build (if needed) and launch it
make clean    # remove build/ and the upad binary
```

Each `src/*.asm` is assembled independently (`nasm -f elf64`) into
`build/*.o`, then linked in one step with `gcc build/*.o -o upad
$(pkg-config --libs gtk4 libadwaita-1)`.

### Troubleshooting

**`pkg-config could not find "gtk4 libadwaita-1"`** even though the -dev
packages are installed: some setups (Homebrew-on-Linux shadowing the
system `pkg-config`, for one) don't have
`/usr/lib/<arch>/pkgconfig` in `PKG_CONFIG_PATH` by default. Find the
`.pc` files and point at them:

```bash
find /usr/lib -name 'gtk4.pc'
export PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig   # adjust to what `find` printed
make
```

**`ld: relocation ... in read-only section '.text'` / `undefined
reference`**: a symbol referenced with `ICALL` (see `src/callconv.inc`)
isn't `global` in the file that defines it. `ICALL` is for calling this
program's *own* functions across files (no PLT indirection); `CCALL` is
for external GTK/GLib/libadwaita/libc functions.

## Run

```bash
./upad                 # blank "Untitled" document
./upad somefile.txt    # opens somefile.txt directly
```

`org.unbloatedpad.Editor.desktop` is provided for installing into a
desktop launcher / file manager "Open With" list; it expects `upad` to
be on `PATH` (e.g. `sudo install -m755 upad /usr/local/bin/upad`), then:

```bash
install -Dm644 org.unbloatedpad.Editor.desktop \
    ~/.local/share/applications/org.unbloatedpad.Editor.desktop
```

## Architecture

Where the original is one file, this port is split by feature area since
there's no byte-count pressure keeping everything crammed together:

| File | Owns |
|---|---|
| `main.asm` | Process entry point (`main`), `AdwApplication` setup, `activate`/`open` signal wiring |
| `window.asm` | Builds the window/menu bar/text view/status bar; dispatches `activate` and `open` (command-line file) signals |
| `menu.asm` | The File/Edit/Format/View/Help `GMenu` model, wrapped in a `GtkPopoverMenuBar` |
| `actions.asm` | Registers every `GAction` (`win.*` / `app.*`) and points it at its handler |
| `fileio.asm` | New/Open/Save/Save As: `GtkFileDialog` for the picker, raw `open`/`read`/`write`/`close` for the bytes |
| `editops.asm` | Undo/Cut/Copy/Paste/Delete/Select All (GTK's own built-in text widget actions) + Time/Date |
| `finddlg.asm` | Find, Replace, and Go To Line dialogs and the search logic behind them |
| `format.asm` | Word Wrap, Font (via `GtkFontDialog`, applied as hand-built CSS), Dark Mode |
| `statusbar.asm` | The "Ln X, Col Y" status bar |
| `unsaved.asm` | Tracks unsaved changes; interposes a Save/Discard/Cancel prompt in front of New/Open/Quit/window-close |
| `about.asm` | Help > About, via `AdwAboutDialog` |
| `accels.asm` | Keyboard accelerators (`Ctrl+N`, `F3`, ...) for actions with no built-in GTK binding |
| `consts.inc` | Every enum/flag/struct-layout constant, each sourced from the installed system headers (see the comment above each block) |
| `extern.inc` | `extern` declarations for every GTK/GLib/libadwaita/libc function called from assembly |
| `callconv.inc` | The System V AMD64 calling-convention discipline every function follows (see below) |

### Calling convention

Every function keeps `rsp` 16-aligned before each `call`, per the SysV
AMD64 ABI (`push rbp` / `mov rbp, rsp` / `sub rsp, N` with `N` always a
multiple of 16). Two macros wrap `call`:

- **`CCALL`** — for external functions (GTK/GLib/libadwaita/libc), via
  their PLT stub (`call foo wrt ..plt`, required for a PIE executable),
  with `AL` zeroed first (the "0 vector registers used" contract that
  matters for the handful of variadic-adjacent calls in the codebase).
- **`ICALL`** — for this program's *own* functions defined in another
  `.asm` file (no PLT indirection needed).

Widget pointers that need to survive a nested call are always stashed in
a `g_*` global (`.bss`) or a genuine `[rbp-N]` stack slot immediately —
never left sitting in a caller-saved register across a `call`, since any
call is free to clobber those.

### Struct layouts

A couple of GTK/GLib structs are stack-allocated directly from assembly
and their exact byte layout matters. Both were verified with `sizeof`/
`offsetof` against the real installed headers on the build machine (see
`consts.inc`), not guessed from documentation:

- `GtkTextIter` — 80 bytes, opaque, documented by GTK as safe to
  stack-allocate at a fixed size.
- `GActionEntry` — 64 bytes (5 pointer-sized fields + 3 reserved/padding).

If you build against a GTK/GLib old or new enough that either changed,
re-verify with a two-line C program before trusting these constants.

## Known limitations

- **File > Print... and File > Page Setup...** are not implemented (the
  menu items exist and stay visibly disabled — GTK4 printing is a whole
  separate subsystem, `GtkPrintOperation`, out of scope for this pass).
- **File read/write errors are silent.** A failed `open()`/`read()`/
  `write()` in `fileio.asm` just leaves the buffer/file untouched instead
  of showing an error dialog.
- **Dark Mode**: forcing *light* isn't guaranteed to fully override a
  desktop whose configured GTK theme is itself an always-dark theme (as
  opposed to using stock Adwaita's own light/dark pair) — see the comment
  above `on_dark_mode_activate` in `format.asm` for why.
- **Replace All + unsaved-changes Save**: if you answer "Save" on the
  unsaved-changes prompt and the document has never been saved before,
  the ensuing Save As is asynchronous and the New/Open/Quit you originally
  asked for is dropped rather than chained after it completes — save,
  then repeat the action.
- No Line Numbers gutter (the original gates this behind a build flag
  too, off by default).
