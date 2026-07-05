; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; menu.asm -- loads the classic File/Edit/Format/View/Help menu bar from
; ui/menu.ui (a GtkBuilder <menu> model, embedded as a GResource -- see
; resources.asm) and wraps it in a GtkPopoverMenuBar widget. See menu.ui
; itself for the label/action/section layout; this file is now just the
; runtime glue that loads it and hands g_view_menu (the View submenu) to
; format.asm, which rewrites its Dark Mode item in place.

%include "callconv.inc"  ; CCALL/ICALL macros
%include "extern.inc"    ; gtk_builder_new_from_resource/gtk_builder_get_object/gtk_popover_menu_bar_new_from_model/g_object_unref

global build_menubar  ; called once from window.asm
global g_view_menu    ; exposed so format.asm's Dark Mode toggle can rewrite this submenu's item text in place

section .bss
    align 8
    ; The View GMenu*, kept as a plain borrowed (non-owning) pointer -- see
    ; the comment where it's assigned below for why that's safe.
    g_view_menu resq 1

section .rodata
    menu_ui_resource_path  db "/org/unbloatedpad/Editor/ui/menu.ui", 0
    id_menubar             db "menubar", 0
    id_view_menu           db "view_menu", 0

section .text

; GtkWidget *build_menubar(void)
; Loads menu.ui's <menu id="menubar"> model and wraps it in a
; GtkPopoverMenuBar, ready to insert into the window's content box.
build_menubar:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16              ; [rbp-8] = the popover menu bar widget (survives the g_object_unref below)  [rbp-16] = the GtkBuilder* (survives both gtk_builder_get_object calls plus that same unref)

    lea  rdi, [rel menu_ui_resource_path]
    CCALL gtk_builder_new_from_resource  ; GtkBuilder *gtk_builder_new_from_resource(const gchar *resource_path)
    mov  [rbp-16], rax

    mov  rdi, [rbp-16]            ; arg1 = builder
    lea  rsi, [rel id_view_menu]  ; arg2 = "view_menu"
    CCALL gtk_builder_get_object  ; GObject *gtk_builder_get_object(GtkBuilder*, const gchar *name) -- borrowed pointer
    ; kept as a borrowed (non-owning) pointer in the global g_view_menu:
    ; on_dark_mode_activate (format.asm) rewrites this menu's Dark Mode
    ; item in place to swap its label between "Dark Mode"/"Light Mode".
    ; Safe to keep unreffed by us -- the top-level "menubar" GMenu (fetched
    ; below, then handed to gtk_popover_menu_bar_new_from_model, which
    ; takes its own reference) holds its own ref on this submenu internally
    ; as part of its own tree, which is what keeps it alive for the app's
    ; whole lifetime, well past the g_object_unref on the builder below.
    mov  [rel g_view_menu], rax

    mov  rdi, [rbp-16]          ; arg1 = builder
    lea  rsi, [rel id_menubar]  ; arg2 = "menubar"
    CCALL gtk_builder_get_object                ; rax = the top-level GMenuModel
    mov  rdi, rax                                ; arg1 = that model, for the call below
    CCALL gtk_popover_menu_bar_new_from_model    ; GtkWidget *gtk_popover_menu_bar_new_from_model(GMenuModel*) -- the actual visible menu-bar widget; takes its own reference on the model
    mov  [rbp-8], rax                            ; stash the widget pointer across the unref below

    mov  rdi, [rbp-16]
    CCALL g_object_unref  ; drop our ref on the builder -- the popover widget's own reference (via the model tree) now keeps menubar/view_menu alive

    mov  rax, [rbp-8]  ; return value = the popover menu bar widget
    leave
    ret
