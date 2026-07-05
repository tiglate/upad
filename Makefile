# Makefile -- UnbloatedPad (Linux/GTK4+libadwaita port of TinyRetroPad), pure x86-64 assembly.
#
# Assembles each src/*.asm with NASM into build/*.o, then links with gcc
# (used purely as the link driver, so we get glibc's CRT startup and
# dynamic linking for free -- GTK/GLib require a fully initialized libc
# anyway). Every line of *our* code is assembly; nothing here is compiled
# from C.

ASM       := nasm
ASMFLAGS  := -f elf64 -g -F dwarf -I src/ -I build/
CC        := gcc

PKGS      := gtk4 libadwaita-1 uchardet
LIBS      := $(shell /usr/bin/pkg-config --libs $(PKGS) 2>/dev/null)

ifeq ($(strip $(LIBS)),)
$(error pkg-config could not find "$(PKGS)". Install libgtk-4-dev, \
libadwaita-1-dev, and libuchardet-dev, and if pkg-config still can't see \
them, see the "Troubleshooting" section in README.md)
endif

GLIB_COMPILE_RESOURCES := $(shell command -v glib-compile-resources 2>/dev/null)
ifeq ($(strip $(GLIB_COMPILE_RESOURCES)),)
$(error glib-compile-resources not found (part of libglib2.0-dev / glib2.0-dev) \
-- needed to compile ui/*.ui into the embedded GResource bundle)
endif

MSGFMT := $(shell command -v msgfmt 2>/dev/null)
ifeq ($(strip $(MSGFMT)),)
$(error msgfmt not found (part of the "gettext" package) -- needed to compile \
po/*.po into the .mo catalogs src/i18n.asm's bindtextdomain looks up)
endif

SRC_DIR   := src
BUILD_DIR := build
SOURCES   := $(wildcard $(SRC_DIR)/*.asm)
INCLUDES  := $(wildcard $(SRC_DIR)/*.inc)
OBJECTS   := $(patsubst $(SRC_DIR)/%.asm,$(BUILD_DIR)/%.o,$(SOURCES))
TARGET    := upad

# --- embedded UI (GtkBuilder XML -> GResource -> linked-in object) -----
# ui/*.ui are compiled by glib-compile-resources into one raw GResource
# binary bundle (build/ui.gresource -- deliberately without
# --generate-source, so no C is generated/compiled anywhere in this
# project), then objcopy turns that binary into build/resources.o, a
# plain relocatable object exposing it as _binary_ui_gresource_start/_end
# (see src/resources.asm, which extern's those two symbols and registers
# the bundle at startup). objcopy is run from inside $(BUILD_DIR) with a
# bare filename so those symbol names come out exactly that -- an input
# path with directory components gets folded into the symbol name too.
UI_DIR      := ui
UI_SOURCES  := $(wildcard $(UI_DIR)/*.ui)
UI_MANIFEST := $(UI_DIR)/ui.gresource.xml

# --- i18n (GNU gettext) -------------------------------------------------
# po/*.po are hand-translated (see po/upad.pot and
# scripts/extract-asm-strings.py for how the .pot is regenerated) and
# compiled by msgfmt into one upad.mo per language. src/i18n.asm's
# setup_i18n looks these up at <exe-dir>/locale/<lang>/LC_MESSAGES/upad.mo
# for an uninstalled dev build (`make && ./upad`, hence LOCALE_DIR being
# a plain top-level directory next to $(TARGET), not under $(BUILD_DIR))
# -- an installed build (`make install`/the .deb) instead puts them at
# $(PREFIX)/share/locale/<lang>/LC_MESSAGES/upad.mo, the system default
# glibc's gettext() already searches on its own, so setup_i18n never even
# calls bindtextdomain in that case.
LINGUAS      := pt_BR es it
PO_DIR       := po
LOCALE_DIR   := locale
MO_FILES     := $(foreach lang,$(LINGUAS),$(LOCALE_DIR)/$(lang)/LC_MESSAGES/upad.mo)
LOCALE_INSTALL_DIR := $(DESTDIR)$(PREFIX)/share/locale

# --- version ---------------------------------------------------------
# Single source of truth for upad's version number: the .version file at
# the repo root, not hardcoded here or duplicated in any .asm file. Feeds
# both .deb packaging (DEB_VERSION below) and the About dialog's version
# field (build/version.inc, generated below, %include-d by src/about.asm).
# `$(shell cat ...)` already strips the trailing newline .version ends
# with, same as a shell `$(...)` substitution would.
VERSION := $(shell cat .version)

# --- install layout -----------------------------------------------------
# PREFIX defaults to /usr/local (a local, non-packaged install); the deb
# target below overrides it to /usr, since that's where distro packages
# belong. DESTDIR is the usual staging-root override for packaging.
PREFIX      ?= /usr/local
DESTDIR     ?=
DESKTOP_ID  := org.unbloatedpad.Editor
BIN_DIR     := $(DESTDIR)$(PREFIX)/bin
DESKTOP_DIR := $(DESTDIR)$(PREFIX)/share/applications
ICON_DIR    := $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps

# --- .deb packaging ---------------------------------------------------
# Runtime deps are the three libraries we link against directly (see
# $(LIBS) above); apt/dpkg resolves their own transitive dependencies
# (harfbuzz, pango, cairo, libstdc++ for uchardet, ...) itself, so those
# aren't listed here.
DEB_VERSION    := $(VERSION)
DEB_ARCH       := amd64
DEB_MAINTAINER := tiglate <128345445+tiglate@users.noreply.github.com>
DEB_DEPENDS    := libgtk-4-1, libadwaita-1-0, libuchardet0
DEB_PKG        := upad_$(DEB_VERSION)_$(DEB_ARCH)
DEB_STAGE      := $(BUILD_DIR)/$(DEB_PKG)

.PHONY: all clean run install uninstall deb release pot

all: $(TARGET) $(MO_FILES)

# Same binary as `all`, minus the DWARF debug info ASMFLAGS bakes in for
# gdb -- that's the only thing `strip` removes here (it isn't loaded into
# memory at runtime either way, only read by a debugger), so this is a
# pure size win with no behavior change: roughly 115KB -> 49KB as of this
# writing. Always rebuilds from a clean tree first, so the result can't
# accidentally be a stripped copy of a stale/partial build.
release: clean $(TARGET)
	strip --strip-all $(TARGET)
	@echo "Stripped release build: $(TARGET) ($$(ls -lh $(TARGET) | awk '{print $$5}')B)"

$(TARGET): $(OBJECTS) $(BUILD_DIR)/ui_data.o
	# -z noexecstack: every src/*.asm object carries its own
	# .note.GNU-stack marker (see callconv.inc) so the linker infers a
	# non-executable stack on its own, but $(BUILD_DIR)/ui_data.o (raw
	# objcopy output, not assembled by us) carries no such marker --
	# without this flag the linker falls back to its old insecure
	# executable-stack default and warns about it.
	$(CC) -o $@ $^ $(LIBS) -Wl,-z,noexecstack

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.asm $(INCLUDES) | $(BUILD_DIR)
	$(ASM) $(ASMFLAGS) -o $@ $<

$(BUILD_DIR)/ui.gresource: $(UI_MANIFEST) $(UI_SOURCES) | $(BUILD_DIR)
	glib-compile-resources --sourcedir=$(UI_DIR) --target=$@ $(UI_MANIFEST)

# Distinct from build/resources.o (the *code* in src/resources.asm, built
# by the pattern rule above) -- this is the *data* blob that code's
# extern'd _binary_ui_gresource_start/_end symbols point into. objcopy
# names those symbols after ui.gresource's basename, not this output
# filename, so naming this ui_data.o rather than resources.o is just to
# not collide with the pattern rule's own build/resources.o target.
$(BUILD_DIR)/ui_data.o: $(BUILD_DIR)/ui.gresource
	cd $(BUILD_DIR) && objcopy -I binary -O elf64-x86-64 -B i386:x86-64 ui.gresource ui_data.o

# One upad.mo per language, at exactly the path an uninstalled dev build
# looks it up from (see the LOCALE_DIR comment above). Unlike $(BUILD_DIR),
# this is NOT gitignored-and-forgotten build noise the user never sees --
# it's an ordinary top-level directory, same standing as icons/, just
# generated rather than hand-authored, so it's gitignored instead.
$(LOCALE_DIR)/%/LC_MESSAGES/upad.mo: $(PO_DIR)/%.po
	mkdir -p $(dir $@)
	$(MSGFMT) -o $@ $<

# Regenerates po/upad.pot from the current source: xgettext's own
# --language=Glade mode handles every translatable="yes" property/
# attribute in ui/*.ui directly, but it has no NASM support at all, so
# scripts/extract-asm-strings.py separately picks up every "; i18n:"-
# marked db "...", 0 string in src/*.asm (see that script's own header)
# -- msgcat merges the two into one .pot. Never runs as part of `all`;
# only invoke by hand after adding/changing a translatable string, then
# `msgmerge --update po/<lang>.po po/upad.pot` each existing translation
# against it.
pot: | $(BUILD_DIR)
	xgettext --language=Glade --from-code=UTF-8 \
	    --package-name=UnbloatedPad --package-version=$(VERSION) \
	    --msgid-bugs-address=https://github.com/tiglate/upad/issues \
	    --copyright-holder="Tiglate Pileser III (tiglate)" \
	    -o $(BUILD_DIR)/ui.pot $(UI_SOURCES)
	python3 scripts/extract-asm-strings.py > $(BUILD_DIR)/asm.pot
	msgcat --use-first -o $(PO_DIR)/upad.pot $(BUILD_DIR)/ui.pot $(BUILD_DIR)/asm.pot

# Generated, not hand-written -- see the VERSION comment above. Lives under
# build/ (gitignored) rather than src/, same reasoning as every other build
# artifact: it's derived, not authored. Only about.o actually needs it (see
# the extra prerequisite line right below), but it's cheap enough to not
# bother scoping the rule any tighter than "regenerate whenever .version changes".
$(BUILD_DIR)/version.inc: .version | $(BUILD_DIR)
	printf '; version.inc -- auto-generated by the Makefile from .version; do not edit directly.\nsection .rodata\nversion_str  db "%s", 0\n' "$(VERSION)" > $@

$(BUILD_DIR)/about.o: $(BUILD_DIR)/version.inc

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

run: $(TARGET)
	./$(TARGET)

# Installs the binary, .desktop launcher, and icon (into the hicolor icon
# theme, named after DESKTOP_ID so icon-theme lookups by app-id -- see
# window.asm's gtk_window_set_icon_name call -- and this project's own
# Icon= key both resolve to it). `make install PREFIX=/usr` for a
# system-wide (as opposed to /usr/local) install. Note this is NOT needed
# just to see the icon in a `make && ./upad` dev build -- window.asm finds
# icons/hicolor itself, relative to the built binary, without installing.
# Depends on `release`, not `$(TARGET)` directly, so anything actually
# installed is always the stripped build, never a leftover debug one.
install: release $(MO_FILES)
	install -Dm755 $(TARGET) $(BIN_DIR)/$(TARGET)
	install -Dm644 $(DESKTOP_ID).desktop $(DESKTOP_DIR)/$(DESKTOP_ID).desktop
	install -Dm644 icons/hicolor/scalable/apps/$(DESKTOP_ID).svg $(ICON_DIR)/$(DESKTOP_ID).svg
	for lang in $(LINGUAS); do \
	    install -Dm644 $(LOCALE_DIR)/$$lang/LC_MESSAGES/upad.mo $(LOCALE_INSTALL_DIR)/$$lang/LC_MESSAGES/upad.mo; \
	done

uninstall:
	rm -f $(BIN_DIR)/$(TARGET) $(DESKTOP_DIR)/$(DESKTOP_ID).desktop $(ICON_DIR)/$(DESKTOP_ID).svg
	for lang in $(LINGUAS); do rm -f $(LOCALE_INSTALL_DIR)/$$lang/LC_MESSAGES/upad.mo; done

# Stages the same install tree (via `install` above, rooted at DEB_STAGE
# with PREFIX=/usr) plus DEBIAN/control metadata, and packs it with
# dpkg-deb. Install with `sudo apt install ./$(DEB_PKG).deb` (plain
# `dpkg -i` won't pull in DEB_DEPENDS automatically). No prerequisite of
# its own -- the `$(MAKE) install` call below depends on `release`,
# which is what actually (re)builds and strips $(TARGET); adding another
# `release`/`$(TARGET)` prerequisite here would just rebuild it twice.
deb:
	rm -rf $(DEB_STAGE)
	$(MAKE) install DESTDIR=$(DEB_STAGE) PREFIX=/usr
	mkdir -p $(DEB_STAGE)/DEBIAN $(DEB_STAGE)/usr/share/doc/upad
	install -m644 LICENSE $(DEB_STAGE)/usr/share/doc/upad/copyright
	printf 'Package: upad\nVersion: %s\nSection: editors\nPriority: optional\nArchitecture: %s\nDepends: %s\nMaintainer: %s\nDescription: A classic Notepad-style text editor\n Linux/GTK4+libadwaita port of TinyRetroPad, written entirely in\n hand-written x86-64 assembly.\n' \
	    "$(DEB_VERSION)" "$(DEB_ARCH)" "$(DEB_DEPENDS)" "$(DEB_MAINTAINER)" \
	    > $(DEB_STAGE)/DEBIAN/control
	dpkg-deb --build --root-owner-group $(DEB_STAGE) $(DEB_PKG).deb
	@echo "Built $(DEB_PKG).deb"

clean:
	rm -rf $(BUILD_DIR) $(TARGET) upad_*.deb $(LOCALE_DIR)
