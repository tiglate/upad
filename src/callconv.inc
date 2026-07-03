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
; the ABI; we never pass float/SSE args to any GTK/GLib/Adwaita entry point
; in this program, so AL = 0 is always correct, whether or not the callee
; happens to be variadic. `wrt ..plt` is required here (not optional): this
; program links as a PIE (Ubuntu/Debian gcc default), and the linker rejects
; a plain PC32-relative `call` straight to an undefined external symbol in a
; PIE object -- it must go through the PLT.
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

; Every object file needs this marker section, or the linker assumes the
; old (insecure) default of an executable stack and warns/links one in.
; %include-ing this once per .asm file emits one such section per object,
; same as a C compiler would per translation unit.
section .note.GNU-stack noalloc noexec nowrite progbits
