; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; extern.inc -- declarations for GLib/GObject/GTK4/libadwaita C functions
; called directly from assembly. Every one of these is a plain (non-macro)
; C ABI entry point exported by libgtk-4.so / libadwaita-1.so / libgobject
; -2.0.so / libgio-2.0.so, resolved at link time via the .dynsym PLT.
;
; Calling convention note: none of the functions below are variadic, but
; we zero AL before every call site anyway (see callconv.inc) so that if
; a call site is ever pointed at a variadic function, the "0 vector
; registers used" contract still holds.

; ---- GObject / GLib -----------------------------------------------------
extern g_signal_connect_data
extern g_object_unref
extern g_object_set_data
extern g_object_get_data
extern g_malloc
extern g_free
extern g_path_get_basename

; ---- GLib/GIO: GResource (resources.asm) / GtkBuilder (window.asm, menu.asm) --
extern g_bytes_new_static
extern g_bytes_unref
extern g_resource_new_from_data
extern g_resources_register
extern gtk_builder_new_from_resource
extern gtk_builder_get_object

; ---- GLib: charset validation/conversion (encoding.asm) ------------------
extern g_utf8_validate
extern g_convert

; ---- GApplication / GAction ----------------------------------------------
extern g_application_run
extern g_application_quit
extern g_action_map_add_action_entries
extern g_simple_action_new
extern g_simple_action_new_stateful
extern g_action_map_add_action

; ---- GMenu ----------------------------------------------------------------
extern g_menu_new
extern g_menu_append
extern g_menu_append_submenu
extern g_menu_append_section
extern g_menu_freeze

; ---- libadwaita -----------------------------------------------------------
extern adw_application_new
extern adw_style_manager_get_default
extern adw_style_manager_get_dark
extern adw_style_manager_set_color_scheme

; ---- GTK4: window / application window -------------------------------------
extern gtk_window_set_title
extern gtk_window_set_default_size
extern gtk_window_set_icon_name
extern gtk_window_present
extern gtk_application_window_new
extern gtk_application_set_menubar
extern gtk_application_window_set_show_menubar
extern gtk_window_set_child

; ---- GTK4/GDK: icon theme (resolving gtk_window_set_icon_name above) -------
extern gdk_display_get_default
extern gtk_icon_theme_get_for_display
extern gtk_icon_theme_add_search_path

; ---- GTK4: widgets ----------------------------------------------------------
extern gtk_box_new
extern gtk_box_append
extern gtk_box_insert_child_after
extern gtk_scrolled_window_new
extern gtk_scrolled_window_set_child
extern gtk_scrolled_window_set_policy
extern gtk_text_view_new
extern gtk_text_view_get_buffer
extern gtk_text_view_set_wrap_mode
extern gtk_text_view_set_monospace
extern gtk_widget_set_vexpand
extern gtk_widget_set_hexpand
extern gtk_widget_add_css_class
extern gtk_popover_menu_bar_new_from_model
extern gtk_widget_set_visible
extern gtk_header_bar_new
extern gtk_window_set_titlebar
extern gtk_application_set_accels_for_action

; ---- GTK4: text buffer -------------------------------------------------------
extern gtk_text_buffer_set_text
extern gtk_text_buffer_get_text
extern gtk_text_buffer_get_bounds
extern gtk_text_buffer_insert_at_cursor
extern gtk_text_buffer_insert
extern gtk_text_buffer_begin_user_action
extern gtk_text_buffer_end_user_action

; ---- GTK4: built-in widget actions ("clipboard.cut", "text.undo", ...) -------
extern gtk_widget_activate_action_variant

; ---- libc: wall-clock time formatting (Edit > Time/Date) ---------------------
extern time
extern localtime
extern strftime

; ---- GTK4: text search / selection / cursor -----------------------------------
extern gtk_text_iter_forward_search
extern gtk_text_buffer_get_start_iter
extern gtk_text_buffer_get_selection_bounds
extern gtk_text_buffer_select_range
extern gtk_text_buffer_place_cursor
extern gtk_text_buffer_get_insert
extern gtk_text_buffer_get_iter_at_mark
extern gtk_text_buffer_get_iter_at_line
extern gtk_text_buffer_delete
extern gtk_text_iter_get_line
extern gtk_text_view_scroll_to_iter

; ---- GTK4: dialog widgets (Find / Replace / Go To Line) ------------------------
extern gtk_window_new
extern gtk_window_set_transient_for
extern gtk_window_set_modal
extern gtk_window_set_resizable
extern gtk_label_new
extern gtk_entry_new
extern gtk_editable_get_text
extern gtk_editable_set_text
extern gtk_button_new_with_mnemonic
extern gtk_spin_button_new_with_range
extern gtk_spin_button_get_value_as_int
extern gtk_spin_button_set_value
extern gtk_spin_button_update
extern gtk_widget_grab_focus
extern gtk_event_controller_key_new
extern gtk_widget_add_controller
extern gtk_event_controller_set_propagation_phase

; ---- GTK4: font dialog (GTK 4.10+) / CSS-based font application --------------
extern gtk_font_dialog_new
extern gtk_font_dialog_choose_font
extern gtk_font_dialog_choose_font_finish
extern gtk_font_dialog_set_filter
extern gtk_custom_filter_new
extern gtk_css_provider_new
extern gtk_css_provider_load_from_string
extern gtk_style_context_add_provider_for_display
extern gdk_display_get_default

; ---- Pango: font description accessors ---------------------------------------
extern pango_font_description_get_family
extern pango_font_description_get_size
extern pango_font_description_free
extern pango_font_description_from_string
extern pango_font_description_to_string
extern pango_font_family_is_monospace
extern pango_font_face_get_type
extern pango_font_face_get_family
extern g_type_check_instance_is_a
extern g_menu_remove
extern g_menu_insert

; ---- GObject/GIO: stateful action (toggle) plumbing ---------------------------
extern g_action_get_state
extern g_variant_get_boolean
extern g_variant_new_boolean
extern g_variant_unref
extern g_simple_action_set_state

; ---- GTK4: status bar label / alignment ----------------------------------------
extern gtk_label_set_text
extern gtk_widget_set_halign
extern gtk_text_iter_get_line_offset

; ---- GTK4: padding/margins ------------------------------------------------------
extern gtk_text_view_set_left_margin
extern gtk_text_view_set_right_margin
extern gtk_text_view_set_top_margin
extern gtk_text_view_set_bottom_margin
extern gtk_widget_set_margin_start
extern gtk_widget_set_margin_end
extern gtk_widget_set_margin_top
extern gtk_widget_set_margin_bottom
extern gtk_window_destroy

; ---- libadwaita: About dialog / unsaved-changes alert -------------------------
extern adw_about_dialog_new
extern adw_about_dialog_set_application_name
extern adw_about_dialog_set_developer_name
extern adw_about_dialog_set_version
extern adw_about_dialog_set_comments
extern adw_about_dialog_set_website
extern adw_about_dialog_set_license_type
extern adw_about_dialog_add_credit_section
extern adw_dialog_present
extern adw_alert_dialog_new
extern adw_alert_dialog_add_response
extern adw_alert_dialog_set_response_appearance
extern adw_alert_dialog_set_default_response
extern adw_alert_dialog_set_close_response
extern adw_alert_dialog_choose
extern adw_alert_dialog_choose_finish

; ---- GTK4: file dialog (GTK 4.10+) --------------------------------------------
extern gtk_file_dialog_new
extern gtk_file_dialog_set_title
extern gtk_file_dialog_open
extern gtk_file_dialog_open_finish
extern gtk_file_dialog_save
extern gtk_file_dialog_save_finish

; ---- GIO: GFile ----------------------------------------------------------------
extern g_file_get_path

; ---- libc: raw POSIX file I/O (thin syscall wrappers, no libc buffering
;      surprises for our purposes -- we do our own single read()/write()
;      calls sized exactly to the file, same shape as the original's
;      CreateFileA/ReadFile/WriteFile path) --------------------------------------
extern open
extern read
extern write
extern close
extern lseek
extern readlink
extern strlen
extern strcmp
extern memcpy

; ---- libc: errno / error-message text (errdlg.asm's error dialog + log) ------
extern __errno_location
extern strerror

; ---- GLib: structured logging (errdlg.asm) ------------------------------------
extern g_log

; ---- GTK4: one-shot notification dialog (GTK 4.10+, errdlg.asm) --------------
extern gtk_alert_dialog_new
extern gtk_alert_dialog_set_detail
extern gtk_alert_dialog_show

; ---- GTK4: URI launcher (GTK 4.10+, about.asm's Help > View Help) ------------
extern gtk_uri_launcher_new
extern gtk_uri_launcher_launch
extern gtk_uri_launcher_launch_finish

; ---- GTK4: printing (printing.asm) -------------------------------------------
extern gtk_print_run_page_setup_dialog_async
extern gtk_page_setup_copy
extern gtk_print_settings_new
extern gtk_print_settings_copy
extern gtk_print_operation_new
extern gtk_print_operation_set_default_page_setup
extern gtk_print_operation_set_print_settings
extern gtk_print_operation_get_print_settings
extern gtk_print_operation_set_job_name
extern gtk_print_operation_set_n_pages
extern gtk_print_operation_run
extern gtk_print_context_create_pango_layout
extern gtk_print_context_get_width
extern gtk_print_context_get_height
extern gtk_print_context_get_cairo_context

; ---- Pango: layout pagination (printing.asm) ---------------------------------
extern pango_layout_set_text
extern pango_layout_set_font_description
extern pango_layout_set_width
extern pango_layout_get_line_count
extern pango_layout_get_iter
extern pango_layout_iter_free
extern pango_layout_iter_next_line
extern pango_layout_iter_get_line_yrange
extern pango_layout_iter_get_line_readonly
extern pango_layout_iter_get_baseline

; ---- Pango/cairo: page drawing (printing.asm) ---------------------------------
extern pango_cairo_show_layout_line
extern cairo_move_to
extern cairo_set_source_rgb

; ---- GTK4: line-number gutter (linenum.asm) ------------------------------------
extern gtk_text_view_set_gutter
extern gtk_text_view_get_visible_rect
extern gtk_text_view_get_line_at_y
extern gtk_text_view_get_line_yrange
extern gtk_text_view_buffer_to_window_coords
extern gtk_text_iter_forward_line
extern gtk_drawing_area_new
extern gtk_drawing_area_set_draw_func
extern gtk_drawing_area_set_content_width
extern gtk_widget_create_pango_layout
extern gtk_widget_queue_draw
extern gtk_scrolled_window_get_vadjustment
extern pango_layout_get_pixel_size
extern pango_cairo_show_layout
extern gtk_text_buffer_get_line_count
