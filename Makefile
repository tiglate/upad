# Makefile -- UnbloatedPad (Linux/GTK4+libadwaita port of TinyRetroPad), pure x86-64 assembly.
#
# Assembles each src/*.asm with NASM into build/*.o, then links with gcc
# (used purely as the link driver, so we get glibc's CRT startup and
# dynamic linking for free -- GTK/GLib require a fully initialized libc
# anyway). Every line of *our* code is assembly; nothing here is compiled
# from C.

ASM       := nasm
ASMFLAGS  := -f elf64 -g -F dwarf -I src/
CC        := gcc

PKGS      := gtk4 libadwaita-1
LIBS      := $(shell /usr/bin/pkg-config --libs $(PKGS) 2>/dev/null)

ifeq ($(strip $(LIBS)),)
$(error pkg-config could not find "$(PKGS)". Install libgtk-4-dev and \
libadwaita-1-dev, and if pkg-config still can't see them, see the \
"Troubleshooting" section in README.md)
endif

SRC_DIR   := src
BUILD_DIR := build
SOURCES   := $(wildcard $(SRC_DIR)/*.asm)
INCLUDES  := $(wildcard $(SRC_DIR)/*.inc)
OBJECTS   := $(patsubst $(SRC_DIR)/%.asm,$(BUILD_DIR)/%.o,$(SOURCES))
TARGET    := upad

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(OBJECTS)
	$(CC) -o $@ $^ $(LIBS)

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.asm $(INCLUDES) | $(BUILD_DIR)
	$(ASM) $(ASMFLAGS) -o $@ $<

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

run: $(TARGET)
	./$(TARGET)

clean:
	rm -rf $(BUILD_DIR) $(TARGET)
