; main.asm -- process entry point and application bootstrap.
;
; main() is the normal C entry point: glibc's CRT (crt1.o, supplied
; automatically by gcc at link time) does all process/TLS/pthread setup
; before calling us with rdi=argc, rsi=argv, rdx=envp, exactly like a C
; program. We need that CRT because GTK/GLib themselves depend on a fully
; initialized libc (malloc, pthreads, locale, ...); everything above that
; line -- the entire editor -- is hand-written assembly calling straight
; into the libgtk-4 / libadwaita / libgio / libgobject C ABI.
;
; What happens here, in order: create the AdwApplication object, connect
; the two signals GLib will call back into (see below for why there are
; two), then hand control to g_application_run -- which does NOT return
; until the user quits. Everything about the actual window/editor is
; built lazily inside window.asm's signal handlers, not here.

%include "consts.inc"          ; G_APPLICATION_HANDLES_OPEN, G_CONNECT_DEFAULT
%include "callconv.inc"        ; CCALL macro + calling-convention discipline
%include "extern.inc"          ; extern declarations for every GTK/GLib call used below

global main                    ; the process entry point gcc's CRT calls
extern on_activate              ; defined in window.asm -- fires when launched with no file argument
extern on_open_signal            ; defined in window.asm -- fires when launched WITH a file argument (see G_APPLICATION_HANDLES_OPEN below)

section .rodata
    ; GApplication's "application ID" -- a reverse-DNS-style string GLib
    ; uses for single-instance bookkeeping (e.g. D-Bus activation), not
    ; anything the user ever sees.
    app_id_str        db "org.unbloatedpad.Editor", 0
    ; GObject signal names, passed to g_signal_connect_data below --
    ; these are matched against libgtk-4/libgio's internal signal tables
    ; by name, not by any compile-time symbol.
    activate_sig_str  db "activate", 0
    open_sig_str      db "open", 0

section .bss
    align 8
    ; Every long-lived widget/object pointer the whole program shares
    ; lives here rather than in a register, since a register isn't safe
    ; to hold something across an arbitrary GTK/GLib call (see
    ; callconv.inc) -- and these specifically need to outlive any single
    ; function call anyway, since they're built once in window.asm and
    ; read from every other .asm file in the program.
    global g_app
    global g_window
    global g_textview
    global g_buffer
    global g_scrolled
    global g_box
    g_app          resq 1      ; AdwApplication*  (is-a GApplication, GtkApplication) -- set below, read everywhere
    g_window       resq 1      ; GtkApplicationWindow* -- set in window.asm's ensure_main_window
    g_textview     resq 1      ; GtkTextView* -- the single text-editing widget
    g_buffer       resq 1      ; GtkTextBuffer* -- g_textview's model; most editing code touches this, not the view
    g_scrolled     resq 1      ; GtkScrolledWindow* -- wraps g_textview
    g_box          resq 1      ; GtkBox* -- top-level vertical layout: menu bar, then scrolled text view, then status bar

section .text

; int main(int argc, char **argv)
; Called by glibc's CRT with rdi=argc, rsi=argv, rdx=envp (envp unused).
main:
    push rbp                   ; save caller's (CRT's) frame pointer
    mov  rbp, rsp               ; establish our frame
    push r12                    ; callee-saved: will hold argc across every call below
    push r13                    ; callee-saved: will hold argv across every call below
    ; Stack alignment check: on entry rsp%16==8 (a `call` instruction's
    ; return-address push always leaves it that way). push rbp -> 0.
    ; push r12 -> 8. push r13 -> 0. So rsp is 16-aligned right here,
    ; which every `call` from this point on requires -- see callconv.inc.

    mov  r12, rdi               ; r12 = argc (rdi is caller-saved -- would not survive the CCALLs below)
    mov  r13, rsi                ; r13 = argv (same reasoning)

    ; --- create the AdwApplication ------------------------------------
    lea  rdi, [rel app_id_str]              ; arg1 = application ID string
    mov  esi, G_APPLICATION_HANDLES_OPEN     ; arg2 = flags -- lets `trpad file.txt` / a file
                                              ; manager's "Open With" work, by making GLib
                                              ; emit the "open" signal (connected below,
                                              ; handled by window.asm's on_open_signal)
                                              ; instead of (or alongside) "activate" when
                                              ; launched with file arguments
    CCALL adw_application_new                ; AdwApplication *adw_application_new(const char *app_id, GApplicationFlags flags)
    mov  [rel g_app], rax                    ; rax = the new (also-a-GApplication) object; stash it globally, we need it for the rest of this function and for the whole program's lifetime

    ; --- connect "activate" (launched with no file argument) ----------
    mov  rdi, [rel g_app]                    ; arg1 = instance to connect the signal on
    lea  rsi, [rel activate_sig_str]         ; arg2 = "activate"
    lea  rdx, [rel on_activate]              ; arg3 = C function pointer GLib will call back into
    xor  ecx, ecx                            ; arg4 = user_data = NULL (on_activate doesn't need any)
    xor  r8, r8                              ; arg5 = destroy_data notifier = NULL (nothing to free when disconnected)
    mov  r9d, G_CONNECT_DEFAULT              ; arg6 = connect flags = 0 (no G_CONNECT_AFTER/SWAPPED)
    CCALL g_signal_connect_data              ; gulong g_signal_connect_data(gpointer instance, const gchar *detailed_signal, GCallback c_handler, gpointer data, GClosureNotify destroy_data, GConnectFlags connect_flags) -- return value (handler id) unused, we never disconnect

    ; --- connect "open" (launched WITH one or more file arguments) ----
    mov  rdi, [rel g_app]
    lea  rsi, [rel open_sig_str]             ; "open"
    lea  rdx, [rel on_open_signal]
    xor  ecx, ecx                            ; user_data = NULL
    xor  r8, r8                              ; destroy_data = NULL
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    ; --- hand control to GLib's main loop -----------------------------
    ; g_application_run parses argv itself (deciding whether to emit
    ; "activate" or "open" based on whether there are non-option
    ; arguments), then runs the GLib main loop until the app quits --
    ; this call does not return until then.
    mov  rdi, [rel g_app]                    ; arg1 = application
    mov  esi, r12d                            ; arg2 = argc (32-bit; gint per the C signature)
    mov  rdx, r13                              ; arg3 = argv
    CCALL g_application_run                     ; int g_application_run(GApplication *application, int argc, char **argv)
    mov  r12d, eax                               ; stash the process exit status in r12 (argc's old slot -- argc is dead now); rax itself won't survive the g_object_unref call below

    ; --- drop our reference to the application object -----------------
    mov  rdi, [rel g_app]
    CCALL g_object_unref                       ; releases the ref g_application_new gave us; the process is exiting anyway, but this keeps things clean under e.g. valgrind

    ; --- return the exit status to the CRT ------------------------------
    mov  eax, r12d               ; the real return value of main()
    pop  r13                     ; restore callee-saved regs in reverse push order
    pop  r12
    pop  rbp
    ret                          ; back to glibc's __libc_start_main, which calls exit(eax)
