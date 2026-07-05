; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; actions.asm -- GAction wiring. Menu items in menu.asm refer to actions by
; name ("win.foo" / "app.foo"); this file is where those names become real
; GSimpleAction objects with activate callbacks, registered on either the
; window's action map (exposed under the "win." prefix automatically by
; GtkApplicationWindow) or the application's (exposed under "app.").
;
; Only actions actually implemented so far are registered. A menu item
; whose action doesn't exist yet is automatically shown insensitive by
; GTK, so the full menu can be built once (menu.asm) and "light up" a
; little more each stage as its action is added here.
;
; g_action_map_add_action_entries (called twice below, once per action
; map) takes a plain C array of `struct GActionEntry` -- see
; GACTION_ENTRY_* in consts.inc for the verified 64-byte layout (name,
; activate fn ptr, parameter_type, state, change_state fn ptr, then 24
; bytes of reserved padding). A non-NULL `state` field (a GVariant text
; literal like "true") is what makes an entry a *stateful* boolean toggle
; -- GTK renders those as checkable menu items automatically; everything
; else here is a plain one-shot action.

%include "consts.inc"    ; GACTION_ENTRY_* layout constants (documentation only in this file -- the struct is laid out literally below)
%include "callconv.inc"  ; CCALL/ICALL macros
%include "extern.inc"    ; extern g_action_map_add_action_entries, g_application_quit

global setup_app_actions  ; called from window.asm's ensure_main_window
global setup_win_actions  ; called from window.asm's ensure_main_window
global on_quit_activate   ; called directly (not as a GAction callback) by unsaved.asm's perform_pending once it's safe to actually quit

extern g_app     ; main.asm -- the GApplication (also the "app." action map)
extern g_window  ; main.asm -- the GtkApplicationWindow (also the "win." action map)
; -- handlers implemented elsewhere, wired into the tables below --
extern on_save_activate              ; fileio.asm
extern on_save_as_activate           ; fileio.asm
extern on_insert_time_date_activate  ; editops.asm
extern setup_textops                 ; editops.asm -- registers Cut/Copy/Paste/Undo/Delete/Select All separately (see there for why)
extern on_find_activate              ; finddlg.asm
extern on_find_next_activate         ; finddlg.asm
extern on_replace_activate           ; finddlg.asm
extern on_goto_activate              ; finddlg.asm
extern on_word_wrap_activate         ; format.asm
extern on_font_activate              ; format.asm
extern on_status_bar_activate        ; statusbar.asm
extern on_dark_mode_activate         ; format.asm
extern on_about_activate             ; about.asm
extern on_view_help_activate         ; about.asm
extern on_page_setup_activate        ; printing.asm
extern on_print_activate             ; printing.asm
extern on_line_numbers_activate      ; linenum.asm
extern on_new_requested              ; unsaved.asm -- dirty-check wrapper around fileio.asm's on_new_activate
extern on_open_requested             ; unsaved.asm -- dirty-check wrapper around fileio.asm's on_open_activate
extern on_quit_requested             ; unsaved.asm -- dirty-check wrapper around on_quit_activate (below)

section .rodata
    ; Plain GAction names (no "win."/"app." prefix -- that prefix is
    ; implicit from which action map/table each name is registered into
    ; below, and only shows up in menu.asm's detailed-action-name strings
    ; like "win.new").
    act_quit_name      db "quit", 0
    act_new_name       db "new", 0
    act_open_name      db "open", 0
    act_save_name      db "save", 0
    act_save_as_name   db "save-as", 0
    act_time_date_name db "insert-time-date", 0
    act_find_name       db "find", 0
    act_find_next_name  db "find-next", 0
    act_replace_name    db "replace", 0
    act_goto_name        db "go-to-line", 0
    act_word_wrap_name   db "word-wrap", 0
    act_word_wrap_state  db "true", 0     ; GVariant text literal -- Word Wrap starts checked, matching gtk_text_view_set_wrap_mode's initial call in window.asm
    act_font_name         db "font", 0
    act_status_bar_name   db "status-bar", 0
    act_status_bar_state  db "true", 0    ; starts checked -- the status bar is visible from launch
    act_dark_mode_name    db "dark-mode", 0
    act_about_name        db "about", 0
    act_view_help_name    db "view-help", 0
    act_page_setup_name   db "page-setup", 0
    act_print_name        db "print", 0
    act_line_numbers_name  db "line-numbers", 0
    act_line_numbers_state db "true", 0    ; starts checked -- Line Numbers is on by default

section .data
    align 8
    ; struct GActionEntry app_actions[1] -- the one action registered on
    ; the *application* rather than the window, because quitting the
    ; whole app isn't really a per-window concept.
    app_actions:
        dq act_quit_name      ; name = "quit" (becomes "app.quit" in menu.asm/accels.asm)
        dq on_quit_requested  ; activate(GSimpleAction*, GVariant*, gpointer) -- goes through unsaved.asm's dirty check first, not straight to on_quit_activate
        dq 0                  ; parameter_type = NULL (takes no GVariant parameter)
        dq 0                  ; state = NULL (stateless -- a plain one-shot action, not a checkbox)
        dq 0                  ; change_state = NULL (only meaningful for stateful actions)
        dq 0, 0, 0            ; reserved padding (GACTION_ENTRY_SIZE's trailing 24 bytes) -- must be present so every entry is exactly 64 bytes, but its contents are unused by GLib today
    app_actions_count equ 1

    align 8
    ; struct GActionEntry win_actions[18] -- everything scoped to the
    ; window's own action map ("win." prefix). Each row is one 64-byte
    ; GActionEntry: name, activate, parameter_type, state, change_state,
    ; then 3 reserved qwords -- see consts.inc's GACTION_ENTRY_* offsets.
    win_actions:
        dq act_new_name,       on_new_requested,            0, 0,                    0,  0, 0, 0
        dq act_open_name,      on_open_requested,           0, 0,                    0,  0, 0, 0
        dq act_save_name,      on_save_activate,            0, 0,                    0,  0, 0, 0
        dq act_save_as_name,   on_save_as_activate,         0, 0,                    0,  0, 0, 0
        dq act_time_date_name, on_insert_time_date_activate,0, 0,                    0,  0, 0, 0
        dq act_find_name,      on_find_activate,            0, 0,                    0,  0, 0, 0
        dq act_find_next_name, on_find_next_activate,       0, 0,                    0,  0, 0, 0
        dq act_replace_name,   on_replace_activate,         0, 0,                    0,  0, 0, 0
        dq act_goto_name,      on_goto_activate,            0, 0,                    0,  0, 0, 0
        dq act_word_wrap_name, on_word_wrap_activate,       0, act_word_wrap_state,  0,  0, 0, 0   ; stateful -> checkable menu item, starts checked
        dq act_font_name,      on_font_activate,            0, 0,                    0,  0, 0, 0
        dq act_status_bar_name,on_status_bar_activate,      0, act_status_bar_state, 0,  0, 0, 0  ; stateful -> checkable menu item, starts checked
        dq act_dark_mode_name, on_dark_mode_activate,       0, 0,                    0,  0, 0, 0  ; deliberately stateless -- format.asm manages dark/light itself and rewrites the menu label directly instead of using GTK's checkbox rendering
        dq act_about_name,     on_about_activate,           0, 0,                    0,  0, 0, 0
        dq act_view_help_name, on_view_help_activate,       0, 0,                    0,  0, 0, 0
        dq act_page_setup_name,on_page_setup_activate,      0, 0,                    0,  0, 0, 0
        dq act_print_name,     on_print_activate,           0, 0,                    0,  0, 0, 0
        dq act_line_numbers_name, on_line_numbers_activate, 0, act_line_numbers_state,0, 0, 0, 0   ; stateful -> checkable menu item, starts checked
    win_actions_count equ 18

section .text

; void on_quit_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
; The *actual* quit: unconditionally tells the GApplication to stop its
; main loop. Never called directly as a GAction handler -- always through
; unsaved.asm's on_quit_requested -> request_close -> perform_pending
; chain, which is what decides *whether* it's safe to call this yet.
on_quit_activate:
    push rbp                  ; save caller's frame pointer
    mov  rbp, rsp             ; establish frame (no locals needed)
    mov  rdi, [rel g_app]     ; arg1 = application
    CCALL g_application_quit  ; void g_application_quit(GApplication*) -- causes g_application_run (main.asm) to return once the main loop unwinds
    pop  rbp
    ret

; void setup_app_actions(void) -- call once, after g_app exists
setup_app_actions:
    push rbp
    mov  rbp, rsp
    mov  rdi, [rel g_app]                  ; arg1 = action map = the application itself
    lea  rsi, [rel app_actions]            ; arg2 = the GActionEntry array above
    mov  edx, app_actions_count            ; arg3 = number of entries (gint) = 1
    xor  ecx, ecx                          ; arg4 = user_data = NULL (no entry here reads it)
    CCALL g_action_map_add_action_entries  ; void g_action_map_add_action_entries(GActionMap*, const GActionEntry *entries, gint n_entries, gpointer user_data) -- registers all of app_actions in one call
    pop  rbp
    ret

; void setup_win_actions(void) -- call once, after g_window exists.
setup_win_actions:
    push rbp
    mov  rbp, rsp
    mov  rdi, [rel g_window]     ; arg1 = action map = the main window
    lea  rsi, [rel win_actions]  ; arg2 = the GActionEntry array above
    mov  edx, win_actions_count  ; arg3 = 18
    xor  ecx, ecx                ; arg4 = user_data = NULL
    CCALL g_action_map_add_action_entries
    ICALL setup_textops                 ; registers Cut/Copy/Paste/Undo/Delete/Select All separately, since they share one dynamically-parameterized handler rather than fitting the static GActionEntry table shape -- see editops.asm
    pop  rbp
    ret
