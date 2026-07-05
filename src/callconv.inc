; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; callconv.inc -- calling-convention discipline shared by every .asm file.
;
; ABI: System V AMD64. Integer/pointer args go in rdi, rsi, rdx, rcx, r8, r9
; in that order; return value in rax. `call` MUST be issued with rsp % 16 == 0
; (the call instruction's own push of the return address then makes rsp % 16
; == 8 at the callee's entry point, which is what every SysV-conforming
; function expects).
;
; Rule followed throughout this codebase: every stack frame's prologue does
;     push rbp
;     mov  rbp, rsp
;     [sub rsp, N]      ; N is always a multiple of 16
; which keeps rsp 16-aligned for every `call` inside the function. Locals
; that need to survive a nested call are kept in the g_* globals (.bss) or
; genuinely pushed/popped on the stack -- never left in caller-saved
; registers (rax, rcx, rdx, rsi, rdi, r8-r11), since any call can clobber
; those.
;
; CCALL: zero AL then call an external (shared-library) function via its PLT
; stub. AL encodes "number of vector registers used for a variadic call" per
; the ABI -- relevant only to functions declared with a trailing `...`
; (gtk_alert_dialog_new, g_log). None of those ever receive a float/SSE
; vararg in this program (only %s string substitutions), so AL = 0 is always
; correct there. Some NON-variadic calls (printing.asm's cairo_move_to,
; cairo_set_source_rgb) do take fixed `double` parameters -- those go
; straight into XMM0/XMM1/... before the CCALL, same as any other argument
; register; AL is irrelevant to a non-variadic callee and zeroing it is
; simply a no-op for those call sites, not a workaround. `wrt ..plt` is
; required here (not optional): this program links as a PIE (Ubuntu/Debian
; gcc default), and the linker rejects a plain PC32-relative `call` straight
; to an undefined external symbol in a PIE object -- it must go through the
; PLT.
%macro CCALL 1
    xor eax, eax
    call %1 wrt ..plt
%endmacro

; ICALL: call one of our own functions, defined in another .asm file of
; this same program (resolved directly by the linker, no PLT indirection
; needed since it isn't crossing a shared-library boundary).
%macro ICALL 1
    xor eax, eax
    call %1
%endmacro

; A 7th (or later) integer/pointer argument doesn't fit in rdi/rsi/rdx/
; rcx/r8/r9 and has to go on the stack instead -- encoding.asm's calls to
; g_convert (7 params) are the first case of this in the codebase. Pattern:
;     sub  rsp, 16              ; one stack slot (8 bytes) + 8 bytes padding,
;                                ; keeping rsp a multiple of 16 at the CCALL
;                                ; below, same invariant as everywhere else
;     mov  qword [rsp], value     ; arg7 goes at [rsp] -- the ABI expects it
;                                  ; directly below the return address CCALL's
;                                  ; own `call` is about to push
;     CCALL some_function
;     add  rsp, 16                ; restore
; A function pointer held in a register (rather than referenced by name,
; so neither CCALL nor ICALL -- both take a symbol -- apply) is called the
; same way ICALL would, just written out: `xor eax, eax` / `call reg`. See
; encoding.asm's ensure_encoding_resolved for the one place this program
; does that, to invoke a caller-supplied continuation once an async
; decision is resolved (or immediately, if there was nothing to decide).

; Every object file needs this marker section, or the linker assumes the
; old (insecure) default of an executable stack and warns/links one in.
; %include-ing this once per .asm file emits one such section per object,
; same as a C compiler would per translation unit.
section .note.GNU-stack noalloc noexec nowrite progbits
