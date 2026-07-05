; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; i18n.asm -- one-time startup setup for GNU gettext, called first thing
; in main() (main.asm), before anything else (in particular, before
; ensure_main_window ever loads a GtkBuilder XML file, since every
; translatable string in those -- and every gettext() call site in the
; rest of this program -- depends on textdomain() having already run).
;
; setlocale(LC_ALL, "") makes the whole C library (strerror(), strftime()'s
; "%c" in editops.asm, etc.) follow whatever the desktop/session's own
; locale is (via $LANG/$LANGUAGE), not the "C" locale glibc starts in by
; default. gettext() then translates every string this program itself
; passes through it, PROVIDED bindtextdomain has pointed the "upad" domain
; at a directory that actually holds a matching <lang>/LC_MESSAGES/upad.mo
; -- which is a different concern for an uninstalled dev build
; (`make && ./upad`, translations live in locale/ next to the executable,
; at the repo root -- see the Makefile's mo-file rule) versus an
; installed one (`make install`/the .deb, which put them at the system
; default the C library already searches, e.g. /usr/share/locale, so
; bindtextdomain isn't even called in that case -- see below). Exactly the same two-cases-one-executable-relative-path
; reasoning as window.asm's register_icon_search_path, just for a
; different subdirectory and a different GLib/libc call at the end.
;
; GtkBuilder's own translatable="yes" properties/attributes (in every
; ui/*.ui file) are translated automatically against the same default
; domain textdomain() sets here -- no per-GtkBuilder-instance call needed
; in window.asm/menu.asm/finddlg.asm.

%include "consts.inc"    ; LC_ALL, F_OK, EXE_PATH_BUF_SIZE
%include "callconv.inc"  ; CCALL/ICALL macros
%include "extern.inc"    ; extern setlocale/bindtextdomain/bind_textdomain_codeset/textdomain/access/readlink

global setup_i18n  ; called once from main.asm, before anything else

extern strcopy_bounded  ; fileio.asm -- bounded string copy/append, reused here for locale_subdir_str's append, same as window.asm's register_icon_search_path

section .rodata
    empty_locale_str    db 0                              ; setlocale's second arg = "" -> follow the environment ($LANG/$LANGUAGE), not a hardcoded locale
    gettext_domain_str  db "upad", 0                       ; matches the .mo files' own basename (upad.mo) and po/*.po's "Project-Id-Version" -- see po/ and the Makefile's msgfmt step
    utf8_codeset_str    db "UTF-8", 0                      ; bind_textdomain_codeset -- guarantees gettext() always hands back UTF-8, regardless of the runtime locale's own native charset, since every GTK/Pango call in this program requires UTF-8 (see encoding.asm's own file header for why that matters generally)
    proc_self_exe_str   db "/proc/self/exe", 0
    locale_subdir_str   db "/locale", 0                    ; appended after this executable's own directory, mirroring window.asm's icons_subdir_str

section .bss
    align 8
    ; readlink("/proc/self/exe") result, truncated at the last '/' to drop
    ; this executable's own filename, then suffixed with locale_subdir_str
    ; -- see setup_i18n below. Deliberately this file's OWN buffer, not a
    ; reuse of window.asm's g_exe_path_buf: that one is filled in later
    ; (register_icon_search_path only runs once ensure_main_window does,
    ; well after this), and duplicating this small a readlink dance is
    ; simpler than threading a cross-file dependency between two otherwise
    ; unrelated one-time startup steps.
    g_locale_dir_buf  resb EXE_PATH_BUF_SIZE

section .text

; void setup_i18n(void) -- see file header.
setup_i18n:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                        ; [rbp-8] = readlink's return value (byte count, or -1)

    mov  edi, LC_ALL                     ; arg1 = category
    lea  rsi, [rel empty_locale_str]       ; arg2 = "" -- follow the environment
    CCALL setlocale                          ; char *setlocale(int category, const char *locale) -- return value (the resulting locale name) not needed

    ; --- find this executable's own directory, same technique as ---------
    ;     window.asm's register_icon_search_path (see its own comments for
    ;     why each step is there; not repeated in as much depth here)
    lea  rdi, [rel proc_self_exe_str]
    lea  rsi, [rel g_locale_dir_buf]
    mov  rdx, EXE_PATH_BUF_SIZE - 32
    CCALL readlink
    mov  [rbp-8], rax
    cmp  qword [rbp-8], 0
    jle  .skip_bindtextdomain                 ; /proc/self/exe unreadable -- give up on the dev-build path quietly, same as register_icon_search_path

    lea  rdi, [rel g_locale_dir_buf]
    add  rdi, [rbp-8]
    mov  byte [rdi], 0

    lea  rdi, [rel g_locale_dir_buf]
    mov  rcx, [rbp-8]
.scan_for_slash:
    dec  rcx
    js   .skip_bindtextdomain
    cmp  byte [rdi + rcx], '/'
    jne  .scan_for_slash
    mov  byte [rdi + rcx], 0

    lea  rdi, [rdi + rcx]
    lea  rsi, [rel locale_subdir_str]  ; "/locale"
    mov  rdx, 32
    ICALL strcopy_bounded              ; fileio.asm -- bounded append, same reuse as register_icon_search_path

    ; --- only bindtextdomain if <exe dir>/locale actually exists ----------
    ; (unlike GtkIconTheme's search path, which tolerates a nonexistent
    ; extra entry just fine, bindtextdomain REPLACES the one location
    ; gettext looks in for this domain -- pointing it at a dev-tree
    ; directory that doesn't exist would break an INSTALLED build, which
    ; relies on never calling this at all so gettext falls back to the
    ; compiled-in system default, e.g. /usr/share/locale, where `make
    ; install`/the .deb actually put the compiled .mo files)
    lea  rdi, [rel g_locale_dir_buf]
    mov  esi, F_OK
    CCALL access                        ; int access(const char *pathname, int mode) -- 0 if it exists, -1 otherwise
    test eax, eax
    jnz  .skip_bindtextdomain

    lea  rdi, [rel gettext_domain_str]
    lea  rsi, [rel g_locale_dir_buf]
    CCALL bindtextdomain  ; char *bindtextdomain(const char *domainname, const char *dirname)

.skip_bindtextdomain:
    lea  rdi, [rel gettext_domain_str]
    lea  rsi, [rel utf8_codeset_str]
    CCALL bind_textdomain_codeset  ; char *bind_textdomain_codeset(const char *domainname, const char *codeset) -- always UTF-8, regardless of which directory (or none) was bound above

    lea  rdi, [rel gettext_domain_str]
    CCALL textdomain  ; char *textdomain(const char *domainname) -- makes "upad" the default domain gettext()/GtkBuilder's translatable="yes" both consult

    leave
    ret
