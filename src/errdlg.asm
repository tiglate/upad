; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; errdlg.asm -- surfaces a failure to the user AND to a durable log, instead
; of failing silently. Two entry points:
;
;   report_error(op_summary, detail) -- the generic form: shows a
;     GtkAlertDialog (GTK 4.10+, a plain one-button "OK" notification, not
;     a Yes/No choice, which is why this doesn't reuse unsaved.asm's
;     AdwAlertDialog machinery -- that one's built for multi-response
;     confirmations, this is pure "here's what went wrong") and logs the
;     same text via g_log(), so it's still recoverable after the dialog is
;     dismissed -- GLib's default log writer sends this to the systemd
;     journal when available, falling back to stderr otherwise. Called
;     directly by printing.asm, whose failures (a GtkPrintOperation error)
;     have no errno/path to build a detail line from.
;
;   report_file_error(op_summary, path, saved_errno) -- fileio.asm's
;     open()/lseek()/read()/write() failures: builds a "<path>: <reason>"
;     detail line via strerror(), then calls report_error with it.
;
; Both the dialog's "message" and g_log's format string are always one of
; this file's own static strings (never attacker/filesystem-controlled
; data) passed through a fixed "%s" rather than used as the format
; directly -- format-string injection is avoided even though we author
; these strings ourselves and don't currently expect a stray '%' in them.
; The one piece of dynamic, filesystem-controlled data (the path) is only
; ever handed to a non-variadic setter (gtk_alert_dialog_set_detail) or
; substituted as a %s argument, never used as a format string itself.

%include "consts.inc"    ; G_LOG_LEVEL_WARNING, ERROR_BUF_SIZE
%include "callconv.inc"  ; CCALL/ICALL macros
%include "extern.inc"    ; __errno_location/strerror/g_log/gtk_alert_dialog_*/g_object_unref

global report_error       ; the generic form -- called from fileio.asm (indirectly, via report_file_error below) and directly from printing.asm
global report_file_error  ; called from fileio.asm at every open()/lseek()/read()/write() failure site

extern g_window         ; main.asm -- parent for the alert dialog
extern strcopy_bounded  ; fileio.asm -- tiny bounded string-copy helper, reused here to build the detail line

section .rodata
    fmt_percent_s  db "%s", 0        ; fixed format used for the dialog's "message" -- see file header for why op_summary is never passed as the format directly
    log_domain     db "upad", 0
    log_fmt        db "%s: %s", 0     ; -> "<op_summary>: <path>: <reason>", since g_errdlg_buf already holds "<path>: <reason>"
    sep_str        db ": ", 0

section .bss
    align 8
    g_errdlg_buf  resb ERROR_BUF_SIZE   ; scratch buffer holding "<path>: <reason>", built fresh on every call -- consumed immediately by both the dialog and g_log, so no reentrancy concern (same reasoning as fileio.asm's g_title_buf)

section .text

; -------------------------------------------------------------------------
; void report_error(const char *op_summary, const char *detail)
;
; op_summary: a short static string naming what failed (e.g. "Could not
;   open file"), owned by the caller (always a .rodata literal).
; detail: the longer explanation shown/logged alongside it -- plain data,
;   never treated as a format string, so it's safe even if it came from
;   the filesystem (a path can contain '%') or is itself just another
;   static string (printing.asm's fixed failure message).
; -------------------------------------------------------------------------
report_error:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=op_summary  [rbp-16]=detail  [rbp-24]=the GtkAlertDialog
    mov  [rbp-8], rdi
    mov  [rbp-16], rsi

    ; --- show the dialog ---------------------------------------------------
    lea  rdi, [rel fmt_percent_s]  ; arg1 = "%s" (fixed format -- see file header)
    mov  rsi, [rbp-8]              ; arg2 = op_summary, substituted for %s
    CCALL gtk_alert_dialog_new     ; GtkAlertDialog *gtk_alert_dialog_new(const char *format, ...) -- rax = a new dialog, we own this reference; no buttons were set, so GTK shows its single default dismiss button
    mov  [rbp-24], rax

    mov  rdi, [rbp-24]  ; arg1 = self
    mov  rsi, [rbp-16]  ; arg2 = detail -- plain data, NOT a format string (gtk_alert_dialog_set_detail isn't variadic)
    CCALL gtk_alert_dialog_set_detail

    mov  rdi, [rbp-24]           ; arg1 = self
    mov  rsi, [rel g_window]     ; arg2 = parent
    CCALL gtk_alert_dialog_show  ; void gtk_alert_dialog_show(GtkAlertDialog*, GtkWindow*) -- shows it and returns immediately; no response to wait for, this is pure notification

    mov  rdi, [rbp-24]
    CCALL g_object_unref                                   ; drop our reference -- same reasoning as fileio.asm's file-dialog calls: GTK keeps its own ref alive for as long as the dialog is actually showing

    ; --- log it (systemd journal if available, else stderr) ----------------
    lea  rdi, [rel log_domain]     ; arg1 = "upad"
    mov  esi, G_LOG_LEVEL_WARNING  ; arg2 = level
    lea  rdx, [rel log_fmt]        ; arg3 = "%s: %s"
    mov  rcx, [rbp-8]              ; arg4 = op_summary
    mov  r8, [rbp-16]              ; arg5 = detail
    CCALL g_log                    ; void g_log(const gchar *log_domain, GLogLevelFlags log_level, const gchar *format, ...)

    leave
    ret

; -------------------------------------------------------------------------
; void report_file_error(const char *op_summary, const char *path, int saved_errno)
;
; op_summary: a short static string naming the failed operation (e.g.
;   "Could not open file"), owned by the caller (always a .rodata literal).
; path: the file path involved, filesystem-controlled -- may contain any
;   byte a POSIX path can, including '%'.
; saved_errno: the errno value from the failing syscall, captured by the
;   CALLER immediately after the failure and before any cleanup call
;   (close()/g_free()) that could otherwise clobber it.
; -------------------------------------------------------------------------
report_file_error:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=op_summary  [rbp-16]=path  [rbp-24]=saved_errno  [rbp-32]=reason (strerror's return, a borrowed static/TLS string)

    mov  [rbp-8], rdi
    mov  [rbp-16], rsi
    movsxd rax, edx                 ; sign-extend the incoming 32-bit errno value into a clean 64-bit stack slot
    mov  [rbp-24], rax

    ; --- strerror(saved_errno) -------------------------------------------
    mov  edi, [rbp-24]  ; low 32 bits of the sign-extended slot == the original errno value exactly
    CCALL strerror      ; char *strerror(int errnum) -- rax = borrowed pointer to a static description string; never ours to free
    mov  [rbp-32], rax

    ; --- build "<path>: <reason>" into g_errdlg_buf -----------------------
    lea  rdi, [rel g_errdlg_buf]
    mov  rsi, [rbp-16]              ; path
    mov  rdx, ERROR_BUF_SIZE - 128  ; reserve a fixed 128-byte tail for the separator + reason (see ERROR_BUF_SIZE's comment in consts.inc) -- a path longer than that is truncated in the display/log text, never a correctness issue
    ICALL strcopy_bounded           ; rax = pointer to the NUL just written, so the next call can chain right after it
    mov  rdi, rax
    lea  rsi, [rel sep_str]                ; ": "
    mov  rdx, 8
    ICALL strcopy_bounded
    mov  rdi, rax
    mov  rsi, [rbp-32]  ; reason
    mov  rdx, 120       ; comfortably within the 128-byte tail reserved above, even after ": " used a couple of bytes of it
    ICALL strcopy_bounded

    mov  rdi, [rbp-8]             ; arg1 = op_summary
    lea  rsi, [rel g_errdlg_buf]  ; arg2 = detail = "<path>: <reason>" (just built above)
    ICALL report_error

    leave
    ret
