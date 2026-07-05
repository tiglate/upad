; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; resources.asm -- registers this program's embedded GResource bundle (the
; GtkBuilder XML under ui/, compiled by the Makefile into build/ui.gresource
; then objcopy'd straight into this executable -- see the Makefile's
; ui.gresource/resources.o rules) so gtk_builder_new_from_resource calls
; elsewhere (window.asm, menu.asm) can find "/org/unbloatedpad/Editor/ui/*"
; at runtime. Must run once, before either of those calls -- called first
; thing in main() (main.asm), ahead of even adw_application_new.

%include "callconv.inc"  ; CCALL macro
%include "extern.inc"    ; g_bytes_new_static/g_bytes_unref/g_resource_new_from_data/g_resources_register/g_log

global register_app_resources

; objcopy -I binary turns build/ui.gresource's raw bytes into this object
; file's .data, exposing its start/end as plain symbols named after the
; input filename -- see the Makefile's resources.o rule, which deliberately
; runs objcopy from inside build/ with a bare "ui.gresource" filename so
; these two names come out exactly like this, independent of BUILD_DIR.
extern _binary_ui_gresource_start
extern _binary_ui_gresource_end

section .rodata
    log_domain      db "upad", 0
    resource_fail_msg db "embedded GResource bundle failed to parse -- corrupt build?", 0

section .text

; void register_app_resources(void)
register_app_resources:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=size (end-start)  [rbp-16]=the GBytes*  [rbp-24]=the GResource* (or NULL on failure)

    lea  rax, [rel _binary_ui_gresource_end]
    lea  rcx, [rel _binary_ui_gresource_start]
    sub  rax, rcx
    mov  [rbp-8], rax

    lea  rdi, [rel _binary_ui_gresource_start]  ; arg1 = data -- this executable's own .rodata/.data, alive for the whole process, so g_bytes_new_static (no copy, no free callback) is exactly right
    mov  rsi, [rbp-8]                           ; arg2 = size
    CCALL g_bytes_new_static                    ; GBytes *g_bytes_new_static(gconstpointer data, gsize size)
    mov  [rbp-16], rax

    mov  rdi, [rbp-16]              ; arg1 = the GBytes
    xor  esi, esi                   ; arg2 = error = NULL -- a malformed bundle here means a broken build, not a runtime/user condition; checked via the NULL return below instead
    CCALL g_resource_new_from_data  ; GResource *g_resource_new_from_data(GBytes*, GError**)
    mov  [rbp-24], rax

    mov  rdi, [rbp-16]     ; the GBytes -- g_resource_new_from_data takes its own reference if it succeeded, so ours is no longer needed either way
    CCALL g_bytes_unref

    mov  rax, [rbp-24]
    test rax, rax
    jnz  .register
    lea  rdi, [rel log_domain]
    mov  esi, 1 << 3                    ; G_LOG_LEVEL_CRITICAL (not pulled into consts.inc for just this one site)
    lea  rdx, [rel resource_fail_msg]
    CCALL g_log
    jmp  .done                          ; nothing to register -- every gtk_builder_new_from_resource call later will simply fail the same way

.register:
    mov  rdi, [rbp-24]
    CCALL g_resources_register  ; void g_resources_register(GResource*) -- takes its own reference; kept alive for the whole process, deliberately never unregistered/unreffed

.done:
    leave
    ret
