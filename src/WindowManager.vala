//
//  Copyright (C) 2012-2014 Tom Beckmann, Rico Tzschichholz
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

using Meta;

namespace Gala
{
	public class WindowManagerGala : Meta.Plugin, WindowManager
	{
		public Clutter.Actor ui_group { get; protected set; }
		public Clutter.Stage stage { get; protected set; }
		public Clutter.Actor window_group { get; protected set; }
		public Clutter.Actor top_window_group { get; protected set; }
		public Meta.BackgroundGroup background_group { get; protected set; }

		public bool block_keybindings_in_modal { get; set; default = true; }

		Meta.PluginInfo info;

		WindowSwitcher? winswitcher = null;
		MultitaskingView? workspace_view = null;
		WindowOverview? window_overview = null;

		// used to detect which corner was used to trigger an action
		Clutter.Actor? last_hotcorner;
		ScreenSaver? screensaver;

		Window? moving; //place for the window that is being moved over

		int modal_count = 0; //count of modal modes overlaying each other

		Gee.HashSet<Meta.WindowActor> minimizing = new Gee.HashSet<Meta.WindowActor> ();
		Gee.HashSet<Meta.WindowActor> maximizing = new Gee.HashSet<Meta.WindowActor> ();
		Gee.HashSet<Meta.WindowActor> unmaximizing = new Gee.HashSet<Meta.WindowActor> ();
		Gee.HashSet<Meta.WindowActor> mapping = new Gee.HashSet<Meta.WindowActor> ();
		Gee.HashSet<Meta.WindowActor> destroying = new Gee.HashSet<Meta.WindowActor> ();

		public WindowManagerGala ()
		{
			info = Meta.PluginInfo () {name = "Gala", version = Config.VERSION, author = "Gala Developers",
				license = "GPLv3", description = "A nice elementary window manager"};

			Prefs.set_ignore_request_hide_titlebar (true);
			Prefs.override_preference_schema ("dynamic-workspaces", Config.SCHEMA + ".behavior");
			Prefs.override_preference_schema ("attach-modal-dialogs", Config.SCHEMA + ".appearance");
			Prefs.override_preference_schema ("button-layout", Config.SCHEMA + ".appearance");
			Prefs.override_preference_schema ("edge-tiling", Config.SCHEMA + ".behavior");
			Prefs.override_preference_schema ("enable-animations", Config.SCHEMA + ".animations");
		}

		public override void start ()
		{
			Util.later_add (LaterType.BEFORE_REDRAW, show_stage);
		}

		bool show_stage ()
		{
			var screen = get_screen ();

			DBus.init (this);
			BackgroundCache.init (screen);
			WindowListener.init (screen);

			// Due to a bug which enables access to the stage when using multiple monitors
			// in the screensaver, we have to listen for changes and make sure the input area
			// is set to NONE when we are in locked mode
			try {
				screensaver = Bus.get_proxy_sync (BusType.SESSION, "org.gnome.ScreenSaver",
					"/org/gnome/ScreenSaver");
				screensaver.active_changed.connect (update_input_area);
			} catch (Error e) {
				screensaver = null;
				warning (e.message);
			}

			stage = Compositor.get_stage_for_screen (screen) as Clutter.Stage;

			var color = BackgroundSettings.get_default ().primary_color;
			stage.background_color = Clutter.Color.from_string (color);

			WorkspaceManager.init (this);

			/* our layer structure, copied from gnome-shell (from bottom to top):
			 * stage
			 * + system background
			 * + ui group
			 * +-- window group
			 * +---- background manager
			 * +-- shell elements
			 * +-- top window group
		     */

			var system_background = new SystemBackground ();
			system_background.add_constraint (new Clutter.BindConstraint (stage,
				Clutter.BindCoordinate.ALL, 0));
			stage.insert_child_below (system_background, null);

			ui_group = new Clutter.Actor ();
			ui_group.reactive = true;
			stage.add_child (ui_group);

			window_group = Compositor.get_window_group_for_screen (screen);
			stage.remove_child (window_group);
			ui_group.add_child (window_group);

			background_group = new BackgroundManager (screen);
			window_group.add_child (background_group);
			window_group.set_child_below_sibling (background_group, null);

			top_window_group = Compositor.get_top_window_group_for_screen (screen);
			stage.remove_child (top_window_group);
			ui_group.add_child (top_window_group);

			/*keybindings*/

			screen.get_display ().add_keybinding ("switch-to-workspace-first", KeybindingSettings.get_default ().schema, 0, () => {
				screen.get_workspace_by_index (0).activate (screen.get_display ().get_current_time ());
			});
			screen.get_display ().add_keybinding ("switch-to-workspace-last", KeybindingSettings.get_default ().schema, 0, () => {
				screen.get_workspace_by_index (screen.n_workspaces - 1).activate (screen.get_display ().get_current_time ());
			});
			screen.get_display ().add_keybinding ("move-to-workspace-first", KeybindingSettings.get_default ().schema, 0, () => {
				var workspace = screen.get_workspace_by_index (0);
				var window = screen.get_display ().get_focus_window ();
				window.change_workspace (workspace);
				workspace.activate_with_focus (window, screen.get_display ().get_current_time ());
			});
			screen.get_display ().add_keybinding ("move-to-workspace-last", KeybindingSettings.get_default ().schema, 0, () => {
				var workspace = screen.get_workspace_by_index (screen.get_n_workspaces () - 1);
				var window = screen.get_display ().get_focus_window ();
				window.change_workspace (workspace);
				workspace.activate_with_focus (window, screen.get_display ().get_current_time ());
			});
			screen.get_display ().add_keybinding ("cycle-workspaces-next", KeybindingSettings.get_default ().schema, 0, () => {
				cycle_workspaces (1);
			});
			screen.get_display ().add_keybinding ("cycle-workspaces-previous", KeybindingSettings.get_default ().schema, 0, () => {
				cycle_workspaces (-1);
			});

			screen.get_display ().overlay_key.connect (() => {
				try {
					Process.spawn_command_line_async (
						BehaviorSettings.get_default ().overlay_action);
				} catch (Error e) { warning (e.message); }
			});

			KeyBinding.set_custom_handler ("panel-main-menu", () => {
				try {
					Process.spawn_command_line_async (
						BehaviorSettings.get_default ().panel_main_menu_action);
				} catch (Error e) { warning (e.message); }
			});

			KeyBinding.set_custom_handler ("toggle-recording", () => {
				try {
					Process.spawn_command_line_async (
						BehaviorSettings.get_default ().toggle_recording_action);
				} catch (Error e) { warning (e.message); }
			});

			KeyBinding.set_custom_handler ("switch-to-workspace-up", () => {});
			KeyBinding.set_custom_handler ("switch-to-workspace-down", () => {});
			KeyBinding.set_custom_handler ("switch-to-workspace-left", handle_switch_to_workspace);
			KeyBinding.set_custom_handler ("switch-to-workspace-right", handle_switch_to_workspace);

			KeyBinding.set_custom_handler ("move-to-workspace-up", () => {});
			KeyBinding.set_custom_handler ("move-to-workspace-down", () => {});
			KeyBinding.set_custom_handler ("move-to-workspace-left",  (d, s, w) => move_window (w, MotionDirection.LEFT) );
			KeyBinding.set_custom_handler ("move-to-workspace-right", (d, s, w) => move_window (w, MotionDirection.RIGHT) );

			KeyBinding.set_custom_handler ("switch-group", () => {});
			KeyBinding.set_custom_handler ("switch-group-backward", () => {});

			/*shadows*/
			InternalUtils.reload_shadow ();
			ShadowSettings.get_default ().notify.connect (InternalUtils.reload_shadow);

			/*hot corner, getting enum values from GraniteServicesSettings did not work, so we use GSettings directly*/
			configure_hotcorners ();
			screen.monitors_changed.connect (configure_hotcorners);

			BehaviorSettings.get_default ().schema.changed.connect ((key) => update_input_area ());

			// initialize plugins and add default components if no plugin overrides them
			var plugin_manager = PluginManager.get_default ();
			plugin_manager.initialize (this);
			plugin_manager.regions_changed.connect (update_input_area);

			if (plugin_manager.workspace_view_provider == null) {
				workspace_view = new MultitaskingView (this);
				ui_group.add_child (workspace_view);

				KeyBinding.set_custom_handler ("show-desktop", () => {
					workspace_view.toggle ();
				});
			}

			if (plugin_manager.window_switcher_provider == null) {
				winswitcher = new WindowSwitcher (this);
				ui_group.add_child (winswitcher);

				//FIXME we have to investigate this. Apparently alt-tab is now bound to switch-applications
				// instead of windows, which we should probably handle too
				KeyBinding.set_custom_handler ("switch-applications", winswitcher.handle_switch_windows);
				KeyBinding.set_custom_handler ("switch-applications-backward", winswitcher.handle_switch_windows);
			}

			if (plugin_manager.window_overview_provider == null) {
				window_overview = new WindowOverview (this);
				ui_group.add_child (window_overview);

				screen.get_display ().add_keybinding ("expose-windows", KeybindingSettings.get_default ().schema, 0, () => {
					window_overview.open (true);
				});
				screen.get_display ().add_keybinding ("expose-all-windows", KeybindingSettings.get_default ().schema, 0, () => {
					window_overview.open (true, true);
				});
			}

			update_input_area ();

			stage.show ();

			// let the session manager move to the next phase
			Meta.register_with_session ();

			Idle.add (() => {
				plugin_manager.load_waiting_plugins ();
				return false;
			});

			return false;
		}

		void configure_hotcorners ()
		{
			var geometry = get_screen ().get_monitor_geometry (get_screen ().get_primary_monitor ());

			add_hotcorner (geometry.x, geometry.y, "hotcorner-topleft");
			add_hotcorner (geometry.x + geometry.width - 1, geometry.y, "hotcorner-topright");
			add_hotcorner (geometry.x, geometry.y + geometry.height - 1, "hotcorner-bottomleft");
			add_hotcorner (geometry.x + geometry.width - 1, geometry.y + geometry.height - 1, "hotcorner-bottomright");

			update_input_area ();
		}

		void add_hotcorner (float x, float y, string key)
		{
			Clutter.Actor hot_corner;
			var stage = Compositor.get_stage_for_screen (get_screen ());

			// if the hot corner already exists, just reposition it, create it otherwise
			if ((hot_corner = stage.find_child_by_name (key)) == null) {
				hot_corner = new Clutter.Actor ();
				hot_corner.width = 1;
				hot_corner.height = 1;
				hot_corner.opacity = 0;
				hot_corner.reactive = true;
				hot_corner.name = key;

				stage.add_child (hot_corner);

				hot_corner.enter_event.connect (() => {
					last_hotcorner = hot_corner;
					perform_action ((ActionType)BehaviorSettings.get_default ().schema.get_enum (key));
					return false;
				});
			}

			hot_corner.x = x;
			hot_corner.y = y;
		}

		void handle_switch_to_workspace (Meta.Display display, Meta.Screen screen, Meta.Window? window,
#if HAS_MUTTER314
			Clutter.KeyEvent event, Meta.KeyBinding binding)
#else
			X.Event event, Meta.KeyBinding binding)
#endif
		{
			var direction = (binding.get_name () == "switch-to-workspace-left" ? MotionDirection.LEFT : MotionDirection.RIGHT);
			switch_to_next_workspace (direction);
		}

		public void switch_to_next_workspace (MotionDirection direction)
		{
			var screen = get_screen ();
			var display = screen.get_display ();
			var active_workspace = screen.get_active_workspace ();
			var neighbor = active_workspace.get_neighbor (direction);

			if (neighbor != active_workspace) {
				neighbor.activate (display.get_current_time ());
				return;
			}

			// if we didnt switch, show a nudge-over animation if one is not already in progress
			if (ui_group.get_transition ("nudge") != null)
				return;

			var dest = (direction == MotionDirection.LEFT ? 32.0f : -32.0f);

			double[] keyframes = { 0.28, 0.58 };
			GLib.Value[] x = { dest, dest };

			var nudge = new Clutter.KeyframeTransition ("x");
			nudge.duration = 360;
			nudge.remove_on_complete = true;
			nudge.progress_mode = Clutter.AnimationMode.LINEAR;
			nudge.set_from_value (0.0f);
			nudge.set_to_value (0.0f);
			nudge.set_key_frames (keyframes);
			nudge.set_values (x);

			ui_group.add_transition ("nudge", nudge);
		}

		public void update_input_area ()
		{
			var schema = BehaviorSettings.get_default ().schema;
			var screen = get_screen ();

			if (screensaver != null) {
				try {
					if (screensaver.get_active ()) {
						InternalUtils.set_input_area (screen, InputArea.NONE);
						return;
					}
				} catch (Error e) {
					// the screensaver object apparently won't be null even though
					// it is unavailable. This error will be thrown however, so we
					// can just ignore it, because if it is thrown, the screensaver
					// is unavailable.
				}
			}

			if (modal_count > 0)
				InternalUtils.set_input_area (screen, InputArea.FULLSCREEN);
			else if (schema.get_enum ("hotcorner-topleft") != ActionType.NONE ||
				schema.get_enum ("hotcorner-topright") != ActionType.NONE ||
				schema.get_enum ("hotcorner-bottomleft") != ActionType.NONE ||
				schema.get_enum ("hotcorner-bottomright") != ActionType.NONE)
				InternalUtils.set_input_area (screen, InputArea.HOT_CORNER);
			else
				InternalUtils.set_input_area (screen, InputArea.NONE);
		}

		public uint32[] get_all_xids ()
		{
			var list = new Gee.ArrayList<uint32> ();

			foreach (var workspace in get_screen ().get_workspaces ()) {
				foreach (var window in workspace.list_windows ())
					list.add ((uint32)window.get_xwindow ());
			}

			return list.to_array ();
		}

		void cycle_workspaces (int direction)
		{
			var screen = get_screen ();
			var index = screen.get_active_workspace_index () + direction;
			if (index < 0)
				index = screen.get_n_workspaces () - 1;
			else if (index > screen.get_n_workspaces () - 1)
				index = 0;

			screen.get_workspace_by_index (index).activate (screen.get_display ().get_current_time ());
		}

		public void move_window (Window? window, MotionDirection direction)
		{
			if (window == null)
				return;

			var screen = get_screen ();
			var display = screen.get_display ();

			var active = screen.get_active_workspace ();
			var next = active.get_neighbor (direction);

			//dont allow empty workspaces to be created by moving, if we have dynamic workspaces
			if (Prefs.get_dynamic_workspaces () && active.n_windows == 1 && next.index () ==  screen.n_workspaces - 1) {
				Utils.bell (screen);
				return;
			}

			moving = window;

			if (!window.is_on_all_workspaces ())
				window.change_workspace (next);

			next.activate_with_focus (window, display.get_current_time ());
		}

		public new void begin_modal ()
		{
			modal_count ++;
			if (modal_count > 1)
				return;

			var screen = get_screen ();
			var display = screen.get_display ();

			update_input_area ();
#if HAS_MUTTER310
			base.begin_modal (0, display.get_current_time ());
#else
			base.begin_modal (x_get_stage_window (Compositor.get_stage_for_screen (screen)), {}, 0, display.get_current_time ());
#endif

			Meta.Util.disable_unredirect_for_screen (screen);
		}

		public new void end_modal ()
		{
			modal_count --;
			if (modal_count > 0)
				return;

			update_input_area ();

			var screen = get_screen ();
			base.end_modal (screen.get_display ().get_current_time ());

			Meta.Util.enable_unredirect_for_screen (screen);
		}

		public bool is_modal ()
		{
			return (modal_count > 0);
		}

		public void get_current_cursor_position (out int x, out int y)
		{
			Gdk.Display.get_default ().get_device_manager ().get_client_pointer ().get_position (null,
				out x, out y);
		}

		public void dim_window (Window window, bool dim)
		{
			/*FIXME we need a super awesome blureffect here, the one from clutter is just... bah!
			var win = window.get_compositor_private () as WindowActor;
			if (dim) {
				if (win.has_effects ())
					return;
				win.add_effect_with_name ("darken", new Clutter.BlurEffect ());
			} else
				win.clear_effects ();*/
		}

		public void perform_action (ActionType type)
		{
			var screen = get_screen ();
			var display = screen.get_display ();
			var current = display.get_focus_window ();

			switch (type) {
				case ActionType.SHOW_WORKSPACE_VIEW:
					workspace_view.toggle ();
					break;
				case ActionType.MAXIMIZE_CURRENT:
					if (current == null || current.window_type != WindowType.NORMAL)
						break;

					if (current.get_maximized () == (MaximizeFlags.HORIZONTAL | MaximizeFlags.VERTICAL))
						current.unmaximize (MaximizeFlags.HORIZONTAL | MaximizeFlags.VERTICAL);
					else
						current.maximize (MaximizeFlags.HORIZONTAL | MaximizeFlags.VERTICAL);
					break;
				case ActionType.MINIMIZE_CURRENT:
					if (current != null && current.window_type == WindowType.NORMAL)
						current.minimize ();
					break;
				case ActionType.OPEN_LAUNCHER:
					try {
						Process.spawn_command_line_async (BehaviorSettings.get_default ().panel_main_menu_action);
					} catch (Error e) {
						warning (e.message);
					}
					break;
				case ActionType.CUSTOM_COMMAND:
					string command = "";
					var line = BehaviorSettings.get_default ().hotcorner_custom_command;
					if (line == "")
						return;

					var parts = line.split (";;");
					// keep compatibility to old version where only one command was possible
					if (parts.length == 1) {
						command = line;
					} else {
						// find specific actions
						var search = last_hotcorner.name;

						foreach (var part in parts) {
							var details = part.split (":");
							if (details[0] == search) {
								command = details[1];
							}
						}
					}

					try {
						Process.spawn_command_line_async (command);
					} catch (Error e) {
						warning (e.message);
					}
					break;
				case ActionType.WINDOW_OVERVIEW:
					window_overview.open (true);
					break;
				case ActionType.WINDOW_OVERVIEW_ALL:
					window_overview.open (true, true);
					break;
				default:
					warning ("Trying to run unknown action");
					break;
			}
		}

#if HAS_MUTTER314
		public override void show_window_menu (Meta.Window window, Meta.WindowMenuType menu, int x, int y)
		{
			//TODO implement window/app menus, their implementation where removed with mutter 3.13+
			switch (menu) {
			case WindowMenuType.WM:
				message ("TODO: show window menu for %s at %ix%i\n", window.get_description (), x, y);
				break;
			case WindowMenuType.APP:
				message ("TODO: show app menu for %s at %ix%i\n", window.get_description (), x, y);
				break;
			}
		}

		public override void show_window_menu_for_rect (Meta.Window window, Meta.WindowMenuType menu, Meta.Rectangle rect)
		{
			show_window_menu (window, menu, rect.x, rect.y);
		}
#endif

		/*
		 * effects
		 */

		public override void minimize (WindowActor actor)
		{
			if (!AnimationSettings.get_default ().enable_animations ||
				AnimationSettings.get_default ().minimize_duration == 0 ||
				actor.get_meta_window ().window_type != WindowType.NORMAL) {
				minimize_completed (actor);
				return;
			}

			kill_window_effects (actor);
			minimizing.add (actor);

			int width, height;
			get_screen ().get_size (out width, out height);

			Rectangle icon = {};
			if (actor.get_meta_window ().get_icon_geometry (out icon)) {

				float scale_x  = (float)icon.width  / actor.width;
				float scale_y  = (float)icon.height / actor.height;
				float anchor_x = (float)(actor.x - icon.x) * actor.width  / (icon.width  - actor.width);
				float anchor_y = (float)(actor.y - icon.y) * actor.height / (icon.height - actor.height);

				actor.move_anchor_point (anchor_x, anchor_y);
				actor.animate (Clutter.AnimationMode.EASE_IN_EXPO, AnimationSettings.get_default ().minimize_duration,
					scale_x:scale_x, scale_y:scale_y,opacity:0)
					.completed.connect (() => {
					//FIXME once we enable this part and we still haven't found a fix for below issue, add the idle here too
					actor.anchor_gravity = Clutter.Gravity.NORTH_WEST;
					actor.opacity = 255;
					actor.scale_x = 1.0;
					actor.scale_y = 1.0;
					minimize_completed (actor);
					minimizing.remove (actor);
				});

			} else {
				actor.scale_center_x = width / 2.0f - actor.x;
				actor.scale_center_y = height - actor.y;
				actor.animate (Clutter.AnimationMode.EASE_IN_EXPO, AnimationSettings.get_default ().minimize_duration,
					scale_x : 0.0f, scale_y : 0.0f, opacity : 0)
					.completed.connect (() => {
					//FIXME for unknown reasons clutter won't apply properties that are changed here,
					//      so we got to use an idle
					Idle.add (() => {
						actor.scale_gravity = Clutter.Gravity.NORTH_WEST;
						actor.opacity = 255;
						actor.scale_x = 1.0;
						actor.scale_y = 1.0;
						minimize_completed (actor);
						minimizing.remove (actor);
						return false;
					});
				});
			}
		}

		//stolen from original mutter plugin
		public override void maximize (WindowActor actor, int ex, int ey, int ew, int eh)
		{
			float x, y, width, height;
			actor.get_size (out width, out height);
			actor.get_position (out x, out y);

			if (!AnimationSettings.get_default ().enable_animations ||
				AnimationSettings.get_default ().snap_duration == 0 ||
				(x == ex && y == ey && ew == width && eh == height)) {
				maximize_completed (actor);
				return;
			}

			if (actor.get_meta_window ().window_type == WindowType.NORMAL) {
				maximizing.add (actor);

				float scale_x  = (float)ew  / width;
				float scale_y  = (float)eh / height;
				float anchor_x = (float)(x - ex) * width  / (ew - width);
				float anchor_y = (float)(y - ey) * height / (eh - height);

				//reset the actor's anchors
				actor.scale_gravity = actor.anchor_gravity = Clutter.Gravity.NORTH_WEST;

				actor.move_anchor_point (anchor_x, anchor_y);
				actor.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, AnimationSettings.get_default ().snap_duration,
					scale_x:scale_x, scale_y:scale_y).get_timeline ().completed.connect ( () => {

					actor.anchor_gravity = Clutter.Gravity.NORTH_WEST;
					actor.set_scale (1.0, 1.0);

					maximizing.remove (actor);
					maximize_completed (actor);
				});

				return;
			}

			maximize_completed (actor);
		}

		public override void map (WindowActor actor)
		{
			if (!AnimationSettings.get_default ().enable_animations) {
				actor.show ();
				map_completed (actor);
				return;
			}

			var window = actor.get_meta_window ();

			actor.detach_animation ();
			actor.show ();

			switch (window.window_type) {
				case WindowType.NORMAL:
					if (AnimationSettings.get_default ().open_duration == 0) {
						map_completed (actor);
						return;
					}

					mapping.add (actor);

					actor.scale_gravity = Clutter.Gravity.SOUTH;
					actor.scale_x = 0.01f;
					actor.scale_y = 0.1f;
					actor.opacity = 0;
					actor.animate (Clutter.AnimationMode.EASE_OUT_EXPO, AnimationSettings.get_default ().open_duration,
						scale_x:1.0f, scale_y:1.0f, opacity:255)
						.completed.connect ( () => {

						mapping.remove (actor);
						map_completed (actor);
					});
					break;
				case WindowType.MENU:
				case WindowType.DROPDOWN_MENU:
				case WindowType.POPUP_MENU:
					if (AnimationSettings.get_default ().menu_duration == 0) {
						map_completed (actor);
						return;
					}

					mapping.add (actor);

					actor.scale_gravity = Clutter.Gravity.CENTER;
					actor.rotation_center_x = {0, 0, 10};
					actor.scale_x = 0.9f;
					actor.scale_y = 0.9f;
					actor.opacity = 0;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, AnimationSettings.get_default ().menu_duration,
						scale_x:1.0f, scale_y:1.0f, opacity:255)
						.completed.connect ( () => {

						mapping.remove (actor);
						map_completed (actor);
					});
					break;
				case WindowType.MODAL_DIALOG:
				case WindowType.DIALOG:

					mapping.add (actor);

					actor.scale_gravity = Clutter.Gravity.NORTH;
					actor.scale_y = 0.0f;
					actor.opacity = 0;

					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 250,
						scale_y:1.0f, opacity:255).completed.connect ( () => {

						mapping.remove (actor);
						map_completed (actor);
					});

					if (AppearanceSettings.get_default ().dim_parents &&
						window.window_type == WindowType.MODAL_DIALOG &&
						window.is_attached_dialog ())
						dim_window (window.find_root_ancestor (), true);

					break;
				default:
					map_completed (actor);
					break;
			}
		}

		public override void destroy (WindowActor actor)
		{
			var window = actor.get_meta_window ();

			if (!AnimationSettings.get_default ().enable_animations) {
				destroy_completed (actor);

				// only NORMAL windows have icons
				if (window.window_type == WindowType.NORMAL)
					Utils.request_clean_icon_cache (get_all_xids ());

				return;
			}

			actor.detach_animation ();

			switch (window.window_type) {
				case WindowType.NORMAL:
					if (AnimationSettings.get_default ().close_duration == 0) {
						destroy_completed (actor);
						return;
					}

					destroying.add (actor);

					actor.scale_gravity = Clutter.Gravity.CENTER;
					actor.show ();
					actor.animate (Clutter.AnimationMode.LINEAR, AnimationSettings.get_default ().close_duration,
						scale_x:0.8f, scale_y:0.8f, opacity:0)
						.completed.connect ( () => {

						destroying.remove (actor);
						destroy_completed (actor);
						Utils.request_clean_icon_cache (get_all_xids ());
					});
					break;
				case WindowType.MODAL_DIALOG:
				case WindowType.DIALOG:
					destroying.add (actor);

					actor.scale_gravity = Clutter.Gravity.NORTH;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 200,
						scale_y:0.0f, opacity:0).completed.connect ( () => {

						destroying.remove (actor);
						destroy_completed (actor);
					});

					dim_window (window.find_root_ancestor (), false);

					break;
				case WindowType.MENU:
				case WindowType.DROPDOWN_MENU:
				case WindowType.POPUP_MENU:
					if (AnimationSettings.get_default ().menu_duration == 0) {
						destroy_completed (actor);
						return;
					}

					destroying.add (actor);

					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, AnimationSettings.get_default ().menu_duration,
						scale_x:0.8f, scale_y:0.8f, opacity:0)
						.completed.connect ( () => {

						destroying.remove (actor);
						destroy_completed (actor);
					});
					break;
				default:
					destroy_completed (actor);
					break;
			}
		}

		public override void unmaximize (Meta.WindowActor actor, int ex, int ey, int ew, int eh)
		{
			if (!AnimationSettings.get_default ().enable_animations || AnimationSettings.get_default ().snap_duration == 0) {
				unmaximize_completed (actor);
				return;
			}

			if (actor.get_meta_window ().window_type == WindowType.NORMAL) {
				unmaximizing.add (actor);

				float x, y, width, height;
				actor.get_size (out width, out height);
				actor.get_position (out x, out y);

				float scale_x  = (float)ew  / width;
				float scale_y  = (float)eh / height;
				float anchor_x = (float)(x - ex) * width  / (ew - width);
				float anchor_y = (float)(y - ey) * height / (eh - height);

				actor.move_anchor_point (anchor_x, anchor_y);
				actor.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, AnimationSettings.get_default ().snap_duration,
					scale_x:scale_x, scale_y:scale_y).completed.connect ( () => {
					actor.move_anchor_point_from_gravity (Clutter.Gravity.NORTH_WEST);
					actor.animate (Clutter.AnimationMode.LINEAR, 1, scale_x:1.0f,
						scale_y:1.0f);//just scaling didnt want to work..

					unmaximizing.remove (actor);
					unmaximize_completed (actor);
				});

				return;
			}

			unmaximize_completed (actor);
		}

		// Cancel attached animation of an actor and reset it
		bool end_animation (ref Gee.HashSet<Meta.WindowActor> list, WindowActor actor)
		{
			if (!list.contains (actor))
				return false;

			if (actor.is_destroyed ()) {
				list.remove (actor);
				return false;
			}

			actor.detach_animation ();
			actor.opacity = 255;
			actor.scale_x = 1.0f;
			actor.scale_y = 1.0f;
			actor.rotation_angle_x = 0.0f;
			actor.anchor_gravity = Clutter.Gravity.NORTH_WEST;
			actor.scale_gravity = Clutter.Gravity.NORTH_WEST;

			list.remove (actor);
			return true;
		}

		public override void kill_window_effects (WindowActor actor)
		{
			if (end_animation (ref mapping, actor))
				map_completed (actor);
			if (end_animation (ref minimizing, actor))
				minimize_completed (actor);
			if (end_animation (ref maximizing, actor))
				maximize_completed (actor);
			if (end_animation (ref unmaximizing, actor))
				unmaximize_completed (actor);
			if (end_animation (ref destroying, actor))
				destroy_completed (actor);
		}

		/*workspace switcher*/
		List<Clutter.Actor>? windows;
		List<Clutter.Actor>? parents;
		List<Clutter.Actor>? tmp_actors;

		public override void switch_workspace (int from, int to, MotionDirection direction)
		{
			if (!AnimationSettings.get_default ().enable_animations
				|| AnimationSettings.get_default ().workspace_switch_duration == 0
				|| (direction != MotionDirection.LEFT && direction != MotionDirection.RIGHT)) {
				switch_workspace_completed ();
				return;
			}

			float screen_width, screen_height;
			var screen = get_screen ();
			var primary = screen.get_primary_monitor ();
			var move_primary_only = InternalUtils.workspaces_only_on_primary ();
			var monitor_geom = screen.get_monitor_geometry (primary);

			screen.get_size (out screen_width, out screen_height);

			unowned Meta.Workspace workspace_from = screen.get_workspace_by_index (from);
			unowned Meta.Workspace workspace_to = screen.get_workspace_by_index (to);

			var main_container = new Clutter.Actor ();
			var static_windows = new Clutter.Actor ();
			var in_group  = new Clutter.Actor ();
			var out_group = new Clutter.Actor ();
			windows = new List<WindowActor> ();
			parents = new List<Clutter.Actor> ();
			tmp_actors = new List<Clutter.Clone> ();

			tmp_actors.append (main_container);
			tmp_actors.append (in_group);
			tmp_actors.append (out_group);
			tmp_actors.append (static_windows);

			window_group.add_child (main_container);

			// prepare wallpaper
			Clutter.Actor wallpaper;
			if (move_primary_only) {
				wallpaper = background_group.get_child_at_index (primary);
				wallpaper.set_data<int> ("prev-x", (int) wallpaper.x);
			} else
				wallpaper = background_group;

			windows.append (wallpaper);
			parents.append (wallpaper.get_parent ());

			var wallpaper_clone = new Clutter.Clone (wallpaper);
			tmp_actors.append (wallpaper_clone);

			clutter_actor_reparent (wallpaper, main_container);
			main_container.add_child (wallpaper_clone);
			main_container.add_child (out_group);
			main_container.add_child (in_group);
			main_container.add_child (static_windows);

			if (moving != null) {
				var moving_actor = (WindowActor) moving.get_compositor_private ();

				windows.append (moving_actor);
				parents.append (moving_actor.get_parent ());

				clutter_actor_reparent (moving_actor, static_windows);
			}

			var to_has_fullscreened = false;
			var from_has_fullscreened = false;
			var docks = new List<WindowActor> ();

			foreach (var actor in Compositor.get_window_actors (screen)) {
				var window = actor.get_meta_window ();

				if (!window.showing_on_its_workspace () ||
					(move_primary_only && window.get_monitor () != primary) ||
					(moving != null && window == moving))
					continue;

				if (window.is_on_all_workspaces ()) {
					// only collect docks here that need to be displayed on both workspaces
					// all other windows will be collected below
					if (window.window_type == WindowType.DOCK) {
						docks.append (actor);
					} else {
						// windows that are on all workspaces will be faded out and back in
						windows.append (actor);
						parents.append (actor.get_parent ());
						clutter_actor_reparent (actor, static_windows);

						actor.save_easing_state ();
						actor.set_easing_duration (300);
						actor.opacity = 0;
						actor.restore_easing_state ();
					}

					continue;
				}

				if (window.get_workspace () == workspace_from) {
					windows.append (actor);
					parents.append (actor.get_parent ());
					clutter_actor_reparent (actor, out_group);

					if (window.fullscreen)
						from_has_fullscreened = true;

				} else if (window.get_workspace () == workspace_to) {
					windows.append (actor);
					parents.append (actor.get_parent ());
					clutter_actor_reparent (actor, in_group);

					if (window.fullscreen)
						to_has_fullscreened = true;

				}
			}

			// make sure we don't add docks when there are fullscreened
			// windows on one of the groups. Simply raising seems not to
			// work, mutter probably reverts the order internally to match
			// the display stack
			foreach (var window in docks) {
				if (!to_has_fullscreened) {
					var clone = new InternalUtils.SafeWindowClone (window.get_meta_window ());
					clone.x = window.x;
					clone.y = window.y;

					in_group.add_child (clone);
					tmp_actors.append (clone);
				}

				if (!from_has_fullscreened) {
					windows.append (window);
					parents.append (window.get_parent ());

					clutter_actor_reparent (window, out_group);
				}
			}

			main_container.clip_to_allocation = true;
			main_container.x = move_primary_only ? monitor_geom.x : 0;
			main_container.y = move_primary_only ? monitor_geom.x : 0;
			main_container.width = move_primary_only ? monitor_geom.width : screen_width;
			main_container.height = move_primary_only ? monitor_geom.height : screen_height;

			var x2 = move_primary_only ? monitor_geom.width : screen_width;
			if (direction == MotionDirection.RIGHT)
				x2 = -x2;

			out_group.x = 0;
			wallpaper.x = 0;
			in_group.x = -x2;
			wallpaper_clone.x = -x2;

			in_group.clip_to_allocation = out_group.clip_to_allocation = true;
			in_group.width = out_group.width = move_primary_only ? monitor_geom.width : screen_width;
			in_group.height = out_group.height = move_primary_only ? monitor_geom.height : screen_height;

			var animation_duration = AnimationSettings.get_default ().workspace_switch_duration;
			var animation_mode = Clutter.AnimationMode.EASE_OUT_CUBIC;

			out_group.set_easing_mode (animation_mode);
			out_group.set_easing_duration (animation_duration);
			in_group.set_easing_mode (animation_mode);
			in_group.set_easing_duration (animation_duration);
			wallpaper_clone.set_easing_mode (animation_mode);
			wallpaper_clone.set_easing_duration (animation_duration);

			wallpaper.save_easing_state ();
			wallpaper.set_easing_mode (animation_mode);
			wallpaper.set_easing_duration (animation_duration);

			out_group.x = x2;
			in_group.x = move_primary_only ? monitor_geom.x : 0;

			wallpaper.x = x2;
			wallpaper_clone.x = move_primary_only ? monitor_geom.x : 0;
			wallpaper.restore_easing_state ();

			var transition = in_group.get_transition ("x");
			if (transition != null)
				transition.completed.connect (end_switch_workspace);
			else
				end_switch_workspace ();
		}

		void end_switch_workspace ()
		{
			if (windows == null || parents == null)
				return;

			var screen = get_screen ();
			var active_workspace = screen.get_active_workspace ();

			for (var i = 0; i < windows.length (); i++) {
				var actor = windows.nth_data (i);

				// to maintain the correct order of monitor, we need to insert the Background
				// back manually
				if (actor is Background) {
					var background = (Background) actor;

					background.get_parent ().remove_child (background);
					background_group.insert_child_at_index (background, background.monitor);
					background.x = background.steal_data<int> ("prev-x");
					continue;
				} else if (actor is BackgroundManager) {
					actor.x = 0;
					// thankfully mutter will take care of stacking it at the right place for us
					clutter_actor_reparent (actor, window_group);
					continue;
				}

				var window = actor as WindowActor;

				if (window == null || !window.is_destroyed ())
					clutter_actor_reparent (actor, parents.nth_data (i));

				if (window == null || window.is_destroyed ())
					continue;

				var meta_window = window.get_meta_window ();
				if (meta_window.get_workspace () != active_workspace
					&& !meta_window.is_on_all_workspaces ())
					window.hide ();

				// some static windows may have been faded out
				if (actor.opacity < 255) {
					actor.save_easing_state ();
					actor.set_easing_duration (300);
					actor.opacity = 255;
					actor.restore_easing_state ();
				}
			}

			if (tmp_actors != null) {
				foreach (var actor in tmp_actors) {
					actor.destroy ();
				}
				tmp_actors = null;
			}

			windows = null;
			parents = null;
			moving = null;

			switch_workspace_completed ();
		}

		public override void kill_switch_workspace ()
		{
			end_switch_workspace ();
		}

		public override bool xevent_filter (X.Event event)
		{
			return x_handle_event (event) != 0;
		}

		public override bool keybinding_filter (Meta.KeyBinding binding)
		{
			return block_keybindings_in_modal && modal_count > 0;
		}

#if HAS_MUTTER310
		public override void confirm_display_change ()
		{
			var pid = Util.show_dialog ("--question",
				_("Does the display look OK?"),
				"30",
				null,
				_("Keep This Configuration"),
				_("Restore Previous Configuration"),
				"preferences-desktop-display",
				0,
				null, null);

			ChildWatch.add (pid, (pid, status) => {
				var ok = false;
				try {
					ok = Process.check_exit_status (status);
				} catch (Error e) {}

				complete_display_change (ok);
			});
		}
#endif

		public override unowned Meta.PluginInfo? plugin_info ()
		{
			return info;
		}

		static void clutter_actor_reparent (Clutter.Actor actor, Clutter.Actor new_parent)
		{
			if (actor == new_parent)
				return;

			actor.ref ();
			actor.get_parent ().remove_child (actor);
			new_parent.add_child (actor);
			actor.unref ();
		}
	}

	[CCode (cname="clutter_x11_handle_event")]
	public extern int x_handle_event (X.Event xevent);
	[CCode (cname="clutter_x11_get_stage_window")]
	public extern X.Window x_get_stage_window (Clutter.Actor stage);
}
