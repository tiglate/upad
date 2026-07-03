; about.asm -- Help > About UnbloatedPad, via AdwAboutDialog (libadwaita
; 1.5+; this build links against 1.5.0).
;
; UnbloatedPad is the Linux/GTK4+libadwaita port of TinyRetroPad (the
; original Win32/MASM project by Dave Plummer and Matt Power). This port
; was written by Tiglate Pileser III (tiglate) with Claude (Anthropic)
; doing the actual assembly authoring under his direction -- see the
; About dialog built below and linux/README.md for the same credit.

%include "consts.inc"          ; GTK_LICENSE_APACHE_2_0
%include "callconv.inc"        ; CCALL macro + calling-convention discipline
%include "extern.inc"          ; extern declarations for every GTK/Adw call used below

global on_about_activate       ; the "win.about" GAction handler, called from actions.asm's win_actions table

extern g_window                 ; main window (main.asm/window.asm) -- About is presented as a child of it

section .rodata
    ; AdwAboutDialog text fields. Every one of these is just a plain
    ; NUL-terminated C string handed to a dedicated setter -- no string
    ; formatting/concatenation needed anywhere in this file.
    app_name_str  db "UnbloatedPad", 0
    dev_name_str  db "Tiglate Pileser III (tiglate)", 0
    version_str   db "Linux port", 0
    comments_str  db "A pure x86-64 assembly recreation of classic Notepad for Linux, built directly on the GTK4 and libadwaita C ABI (no C glue code). This Linux port was created by Tiglate Pileser III (tiglate) using Claude (Anthropic) as the assembly author, based on the original Win32/MASM TinyRetroPad.", 0
    website_str   db "https://github.com/davepl/TinyRetroPad", 0

    ; "Original Windows Edition" credit section: adw_about_dialog_add_credit_section
    ; wants a NULL-terminated array of "Name" (or "Name <email>") strings,
    ; not a single blob, so the two author names are separate C strings...
    credit_name_1 db "Dave Plummer", 0
    credit_name_2 db "Matt Power", 0
    credit_section_title db "Original Windows Edition (TinyRetroPad)", 0

section .data
    align 8
    ; ...referenced from this array, which is what actually gets passed as
    ; the "const char **people" argument. The trailing 0 is the required
    ; NULL terminator that tells GTK where the list of names ends.
    credit_people:
        dq credit_name_1
        dq credit_name_2
        dq 0

section .text

; void on_about_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
;
; Builds a fresh AdwAboutDialog every time (About is opened rarely enough
; that there's no benefit to caching/reusing one, unlike e.g. the Font
; dialog which the user might reopen repeatedly) and immediately shows it.
on_about_activate:
    push rbp                              ; save caller's frame pointer
    mov  rbp, rsp                         ; establish our own frame
    sub  rsp, 16                          ; reserve one 8-byte local slot (16 for alignment): [rbp-8] = the AdwAboutDialog* we're building

    ; --- construct the dialog object ---------------------------------
    CCALL adw_about_dialog_new            ; AdwDialog *adw_about_dialog_new(void) -- rax = new dialog, owned by us until we hand it to adw_dialog_present below
    mov  [rbp-8], rax                     ; stash it -- every field-setter call below will clobber rax via its own CCALL

    ; --- fill in the informational fields, one setter call each ------
    mov  rdi, [rbp-8]                     ; arg1 = self (the dialog)
    lea  rsi, [rel app_name_str]          ; arg2 = "UnbloatedPad"
    CCALL adw_about_dialog_set_application_name

    mov  rdi, [rbp-8]                     ; reload self -- rdi is caller-saved, the previous CCALL may have clobbered it
    lea  rsi, [rel dev_name_str]          ; "Tiglate Pileser III (tiglate)" -- the Linux port's author
    CCALL adw_about_dialog_set_developer_name

    mov  rdi, [rbp-8]
    lea  rsi, [rel version_str]           ; "Linux port" -- distinguishes this build from the Windows original in the same About-style dialog
    CCALL adw_about_dialog_set_version

    mov  rdi, [rbp-8]
    lea  rsi, [rel comments_str]          ; long-form description, incl. the AI-assisted-authorship note
    CCALL adw_about_dialog_set_comments

    mov  rdi, [rbp-8]
    lea  rsi, [rel website_str]           ; upstream project repo (the original Windows TinyRetroPad this is ported from)
    CCALL adw_about_dialog_set_website

    mov  rdi, [rbp-8]
    mov  esi, GTK_LICENSE_APACHE_2_0      ; matches the Apache-2.0 LICENSE.TXT this whole repository (Windows original + this port) ships under
    CCALL adw_about_dialog_set_license_type

    ; --- add a separate credit section naming the original authors ---
    mov  rdi, [rbp-8]                     ; self
    lea  rsi, [rel credit_section_title]  ; "Original Windows Edition (TinyRetroPad)"
    lea  rdx, [rel credit_people]         ; NULL-terminated {Dave Plummer, Matt Power, NULL} array built above
    CCALL adw_about_dialog_add_credit_section

    ; --- show it, parented to the main window -------------------------
    mov  rdi, [rbp-8]                     ; self
    mov  rsi, [rel g_window]              ; parent -- AdwDialog presents itself modally/as-a-sheet relative to this window
    CCALL adw_dialog_present

    leave                                  ; mov rsp, rbp; pop rbp -- tear down our frame
    ret                                    ; back to whatever invoked the "about" action (GTK's action-activation machinery)
