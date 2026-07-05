; menu.asm -- builds the classic File/Edit/Format/View/Help menu bar as a
; GMenu model tree, then wraps it in a GtkPopoverMenuBar widget. Every
; label/mnemonic below is a direct port of the original trpad.asm menu
; text (MFile, MNew, MOpen, ... in trpad.asm), just with GTK's "_"
; mnemonic marker instead of Win32's "&".
;
; Menu items reference actions by name ("win.foo" is resolved against the
; GtkApplicationWindow's own action map; "app.foo" against the
; GApplication's). See actions.asm for which of those are wired up so far
; -- an item pointing at an action that doesn't exist yet is automatically
; rendered insensitive by GTK, so this whole tree can be built once and
; "filled in" stage by stage.
;
; GMenu shape reminder, since the whole file is built from four GLib
; calls repeated many times: g_menu_new() makes an empty GMenu (a
; GMenuModel subclass); g_menu_append(menu, label, detailed_action) adds
; one leaf item to it; g_menu_append_submenu(parent, label, submenu)
; nests one GMenu inside another as a labelled drop-down;
; g_menu_append_section(parent, label, section) nests one GMenu inside
; another the same way, but rendered inline (no nested drop-down) with a
; separator line drawn between it and whatever came before/after --
; that's the only way a GMenu model tree produces the classic horizontal
; menu separator, which is why File and Edit below are each built as
; several small per-section GMenu objects (label always NULL -- these are
; unlabeled groups, the separator is the only visible effect) rather than
; one flat list of items. Every "append a submenu"/"append a section"
; call is immediately followed by g_object_unref on the just-built
; GMenu: both take their own reference, so our local one is no longer
; needed -- the submenu/section stays alive because its parent
; (eventually the popover menu bar widget, which lives for the whole
; program) still holds a reference to it.

%include "consts.inc"    ; GTK_ORIENTATION_* (unused directly here, included for consistency)
%include "callconv.inc"  ; CCALL/ICALL macros
%include "extern.inc"    ; extern g_menu_new/g_menu_append/g_menu_append_submenu/gtk_popover_menu_bar_new_from_model/g_object_unref

global build_menubar  ; called once from window.asm
global g_view_menu    ; exposed so format.asm's Dark Mode toggle can rewrite this submenu's item text in place

section .bss
    align 8
    ; The View GMenu*, kept as a plain borrowed (non-owning) pointer --
    ; see the comment where it's assigned below for why that's safe.
    g_view_menu resq 1

section .rodata
    ; ---- top-level menu titles (the "_X" underscore marks the Alt+X mnemonic) ----
    sub_file    db "_File", 0
    sub_edit    db "_Edit", 0
    sub_format  db "F_ormat", 0
    sub_view    db "_View", 0
    sub_help    db "_Help", 0

    ; ---- File: label + detailed-action-name pairs, in menu order ----
    lbl_new         db "_New", 0
    act_new         db "win.new", 0
    lbl_open        db "_Open...", 0
    act_open        db "win.open", 0
    lbl_save        db "_Save", 0
    act_save        db "win.save", 0
    lbl_save_as     db "Save _As...", 0
    act_save_as     db "win.save-as", 0
    lbl_page_setup  db "Page Set_up...", 0
    act_page_setup  db "win.page-setup", 0
    lbl_print       db "_Print...", 0
    act_print       db "win.print", 0
    lbl_exit        db "E_xit", 0
    act_exit        db "app.quit", 0           ; note the "app." prefix, not "win." -- quitting is application-scoped, registered in actions.asm's app_actions table

    ; ---- Edit ----
    lbl_undo        db "_Undo", 0
    act_undo        db "win.undo", 0
    lbl_cut         db "Cu_t", 0
    act_cut         db "win.cut", 0
    lbl_copy        db "_Copy", 0
    act_copy        db "win.copy", 0
    lbl_paste       db "_Paste", 0
    act_paste       db "win.paste", 0
    lbl_delete      db "De_lete", 0
    act_delete      db "win.delete", 0
    lbl_find        db "_Find...", 0
    act_find        db "win.find", 0
    lbl_find_next   db "Find _Next", 0
    act_find_next   db "win.find-next", 0
    lbl_replace     db "_Replace...", 0
    act_replace     db "win.replace", 0
    lbl_goto        db "_Go To...", 0
    act_goto        db "win.go-to-line", 0
    lbl_select_all  db "Select _All", 0
    act_select_all  db "win.select-all", 0
    lbl_time_date   db "Time/_Date", 0
    act_time_date   db "win.insert-time-date", 0

    ; ---- Format ----
    lbl_word_wrap   db "_Word Wrap", 0          ; stateful boolean action (see actions.asm) -- GTK renders this as a checkable item automatically
    act_word_wrap   db "win.word-wrap", 0
    lbl_font        db "_Font...", 0
    act_font        db "win.font", 0

    ; ---- View ----
    lbl_status_bar  db "_Status Bar", 0         ; also a stateful boolean action -> checkable item
    act_status_bar  db "win.status-bar", 0
    lbl_dark_mode   db "Dark _Mode", 0          ; initial label text; format.asm's relabel_dark_mode_item swaps this for "Light _Mode" once dark mode is active (this is a plain stateless action, not a checkbox -- see format.asm)
    act_dark_mode   db "win.dark-mode", 0
    lbl_line_numbers db "_Line Numbers", 0       ; also a stateful boolean action -> checkable item; kept AFTER Dark Mode rather than before it so DARK_MODE_MENU_INDEX (consts.inc) doesn't need to change
    act_line_numbers db "win.line-numbers", 0

    ; ---- Help ----
    lbl_view_help   db "_View Help", 0
    act_view_help   db "win.view-help", 0
    lbl_about       db "_About UnbloatedPad", 0
    act_about       db "win.about", 0

section .text

; void menu_item(GMenu *menu, const gchar *label, const gchar *action)
; Appends one leaf item (rdi=menu, rsi=label, rdx=detailed action name) --
; a thin wrapper purely so the call sites below read as one line each
; instead of three (load rdi/rsi/rdx, then CCALL). Trivial, but it's what
; keeps build_menubar below from being three times as long.
menu_item:
    push rbp             ; save caller's frame pointer
    mov  rbp, rsp        ; establish frame (no locals -- args already sit exactly where g_menu_append wants them)
    CCALL g_menu_append  ; void g_menu_append(GMenu *menu, const gchar *label, const gchar *detailed_action)
    pop  rbp
    ret

; GtkWidget *build_menubar(void)
; Builds the whole File/Edit/Format/View/Help tree and returns the
; GtkPopoverMenuBar widget ready to pack into the window's content box.
build_menubar:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32              ; three local slots, reused across all five menus:
                               ; [rbp-8]  = menu_bar (the top-level GMenu, lives for the whole function)
                               ; [rbp-16] = "current submenu" scratch -- whichever of File/Edit/Format/View/Help we're building right now
                               ; [rbp-24] = "current section" scratch -- only File and Edit below split their submenu into several of these (see the GMenu-shape comment above), one at a time

    CCALL g_menu_new   ; GMenu *g_menu_new(void) -- the top-level menu bar model
    mov  [rbp-8], rax  ; menu_bar

    ; =================== File ===================
    CCALL g_menu_new           ; the File drop-down itself -- now just a container of sections, no leaf items appended to it directly
    mov  [rbp-16], rax

    ; --- section 1: New, Open, Save, Save As ---
    CCALL g_menu_new
    mov  [rbp-24], rax
    mov  rdi, [rbp-24]       ; menu = section 1
    lea  rsi, [rel lbl_new]  ; label = "_New"
    lea  rdx, [rel act_new]  ; action = "win.new"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_open]  ; "_Open..."
    lea  rdx, [rel act_open]  ; "win.open"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_save]  ; "_Save"
    lea  rdx, [rel act_save]  ; "win.save"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_save_as]  ; "Save _As..."
    lea  rdx, [rel act_save_as]  ; "win.save-as"
    ICALL menu_item
    mov  rdi, [rbp-16]           ; parent = File submenu
    xor  esi, esi                ; label = NULL -- unlabeled section, just produces a separator
    mov  rdx, [rbp-24]           ; section = what we just built
    CCALL g_menu_append_section  ; void g_menu_append_section(GMenu*, const gchar *label, GMenuModel *section) -- takes its own ref
    mov  rdi, [rbp-24]
    CCALL g_object_unref              ; drop our local ref, same reasoning as g_menu_append_submenu below

    ; --- section 2: Page Setup, Print (separator above, from section 1) ---
    CCALL g_menu_new
    mov  [rbp-24], rax
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_page_setup]  ; "Page Set_up..."
    lea  rdx, [rel act_page_setup]  ; "win.page-setup"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_print]  ; "_Print..."
    lea  rdx, [rel act_print]  ; "win.print"
    ICALL menu_item
    mov  rdi, [rbp-16]
    xor  esi, esi
    mov  rdx, [rbp-24]
    CCALL g_menu_append_section
    mov  rdi, [rbp-24]
    CCALL g_object_unref

    ; --- section 3: Exit (separator above, from section 2) ---
    CCALL g_menu_new
    mov  [rbp-24], rax
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_exit]  ; "E_xit"
    lea  rdx, [rel act_exit]  ; "app.quit"
    ICALL menu_item
    mov  rdi, [rbp-16]
    xor  esi, esi
    mov  rdx, [rbp-24]
    CCALL g_menu_append_section
    mov  rdi, [rbp-24]
    CCALL g_object_unref

    ; nest the finished File submenu into the menu bar under the label "_File"
    mov  rdi, [rbp-8]            ; parent = menu_bar
    lea  rsi, [rel sub_file]     ; label = "_File"
    mov  rdx, [rbp-16]           ; submenu = what we just built
    CCALL g_menu_append_submenu  ; void g_menu_append_submenu(GMenu*, const gchar *label, GMenuModel *submenu) -- takes its own ref
    mov  rdi, [rbp-16]
    CCALL g_object_unref           ; drop our local ref -- menu_bar (via append_submenu) now owns the only one that matters

    ; =================== Edit ===================
    CCALL g_menu_new    ; the Edit drop-down itself -- same sections-as-separators approach as File above
    mov  [rbp-16], rax  ; reuse the same scratch slot for the Edit submenu

    ; --- section 1: Undo ---
    CCALL g_menu_new
    mov  [rbp-24], rax
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_undo]  ; "_Undo"
    lea  rdx, [rel act_undo]  ; "win.undo"
    ICALL menu_item
    mov  rdi, [rbp-16]  ; parent = Edit submenu
    xor  esi, esi       ; label = NULL
    mov  rdx, [rbp-24]
    CCALL g_menu_append_section
    mov  rdi, [rbp-24]
    CCALL g_object_unref

    ; --- section 2: Cut, Copy, Paste, Delete (separator above) ---
    CCALL g_menu_new
    mov  [rbp-24], rax
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_cut]  ; "Cu_t"
    lea  rdx, [rel act_cut]  ; "win.cut"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_copy]  ; "_Copy"
    lea  rdx, [rel act_copy]  ; "win.copy"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_paste]  ; "_Paste"
    lea  rdx, [rel act_paste]  ; "win.paste"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_delete]  ; "De_lete"
    lea  rdx, [rel act_delete]  ; "win.delete"
    ICALL menu_item
    mov  rdi, [rbp-16]
    xor  esi, esi
    mov  rdx, [rbp-24]
    CCALL g_menu_append_section
    mov  rdi, [rbp-24]
    CCALL g_object_unref

    ; --- section 3: Find, Find Next, Replace, Go To (separator above) ---
    CCALL g_menu_new
    mov  [rbp-24], rax
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_find]  ; "_Find..."
    lea  rdx, [rel act_find]  ; "win.find"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_find_next]  ; "Find _Next"
    lea  rdx, [rel act_find_next]  ; "win.find-next"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_replace]  ; "_Replace..."
    lea  rdx, [rel act_replace]  ; "win.replace"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_goto]  ; "_Go To..."
    lea  rdx, [rel act_goto]  ; "win.go-to-line"
    ICALL menu_item
    mov  rdi, [rbp-16]
    xor  esi, esi
    mov  rdx, [rbp-24]
    CCALL g_menu_append_section
    mov  rdi, [rbp-24]
    CCALL g_object_unref

    ; --- section 4: Select All, Time/Date (separator above) ---
    CCALL g_menu_new
    mov  [rbp-24], rax
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_select_all]  ; "Select _All"
    lea  rdx, [rel act_select_all]  ; "win.select-all"
    ICALL menu_item
    mov  rdi, [rbp-24]
    lea  rsi, [rel lbl_time_date]  ; "Time/_Date"
    lea  rdx, [rel act_time_date]  ; "win.insert-time-date"
    ICALL menu_item
    mov  rdi, [rbp-16]
    xor  esi, esi
    mov  rdx, [rbp-24]
    CCALL g_menu_append_section
    mov  rdi, [rbp-24]
    CCALL g_object_unref

    mov  rdi, [rbp-8]         ; parent = menu_bar
    lea  rsi, [rel sub_edit]  ; label = "_Edit"
    mov  rdx, [rbp-16]        ; submenu = the Edit menu just built
    CCALL g_menu_append_submenu
    mov  rdi, [rbp-16]
    CCALL g_object_unref            ; same ownership handoff as File, above

    ; =================== Format ===================
    CCALL g_menu_new
    mov  [rbp-16], rax

    mov  rdi, [rbp-16]
    lea  rsi, [rel lbl_word_wrap]  ; "_Word Wrap" -- checkable (stateful action)
    lea  rdx, [rel act_word_wrap]  ; "win.word-wrap"
    ICALL menu_item
    mov  rdi, [rbp-16]
    lea  rsi, [rel lbl_font]  ; "_Font..."
    lea  rdx, [rel act_font]  ; "win.font"
    ICALL menu_item

    mov  rdi, [rbp-8]
    lea  rsi, [rel sub_format]      ; "F_ormat"
    mov  rdx, [rbp-16]
    CCALL g_menu_append_submenu
    mov  rdi, [rbp-16]
    CCALL g_object_unref

    ; =================== View ===================
    CCALL g_menu_new
    mov  [rbp-16], rax
    ; kept as a borrowed (non-owning) pointer in the global g_view_menu:
    ; on_dark_mode_activate (format.asm) rewrites this menu's Dark Mode
    ; item in place to swap its label between "Dark Mode"/"Light Mode".
    ; Safe to keep unreffed by us below -- g_menu_append_submenu takes its
    ; own ref, and that (via the popover menu bar widget holding
    ; menu_bar, which holds this) keeps it alive for the app's whole
    ; lifetime, well past this function returning.
    mov  [rel g_view_menu], rax     ; rax is still the fresh GMenu* from g_menu_new above -- no call has happened since to clobber it

    mov  rdi, [rbp-16]
    lea  rsi, [rel lbl_status_bar]  ; "_Status Bar" -- checkable (stateful action)
    lea  rdx, [rel act_status_bar]  ; "win.status-bar"
    ICALL menu_item
    mov  rdi, [rbp-16]
    lea  rsi, [rel lbl_dark_mode]  ; "Dark _Mode" (initial text; see format.asm)
    lea  rdx, [rel act_dark_mode]  ; "win.dark-mode"
    ICALL menu_item
    mov  rdi, [rbp-16]
    lea  rsi, [rel lbl_line_numbers]  ; "_Line Numbers" -- checkable (stateful action), on by default
    lea  rdx, [rel act_line_numbers]  ; "win.line-numbers"
    ICALL menu_item

    mov  rdi, [rbp-8]
    lea  rsi, [rel sub_view]        ; "_View"
    mov  rdx, [rbp-16]
    CCALL g_menu_append_submenu
    mov  rdi, [rbp-16]
    CCALL g_object_unref

    ; =================== Help ===================
    CCALL g_menu_new
    mov  [rbp-16], rax

    mov  rdi, [rbp-16]
    lea  rsi, [rel lbl_view_help]  ; "_View Help" -- opens this project's GitHub repo (about.asm)
    lea  rdx, [rel act_view_help]  ; "win.view-help"
    ICALL menu_item
    mov  rdi, [rbp-16]
    lea  rsi, [rel lbl_about]  ; "_About UnbloatedPad"
    lea  rdx, [rel act_about]  ; "win.about"
    ICALL menu_item

    mov  rdi, [rbp-8]
    lea  rsi, [rel sub_help]        ; "_Help"
    mov  rdx, [rbp-16]
    CCALL g_menu_append_submenu
    mov  rdi, [rbp-16]
    CCALL g_object_unref

    ; =================== wrap the finished model in a widget ===================
    mov  rdi, [rbp-8]                          ; the fully-built menu_bar model
    CCALL gtk_popover_menu_bar_new_from_model  ; GtkWidget *gtk_popover_menu_bar_new_from_model(GMenuModel*) -- this is the actual visible menu-bar widget
    mov  [rbp-16], rax                         ; stash the widget pointer across the unref below (reusing the scratch slot one last time)

    mov  rdi, [rbp-8]
    CCALL g_object_unref                        ; drop our ref on menu_bar -- the popover widget now holds its own, keeping the whole tree (and g_view_menu) alive

    mov  rax, [rbp-16]  ; return value = the popover menu bar widget
    leave               ; mov rsp, rbp; pop rbp
    ret
