//
//  Copyright (C) 2014 Tom Beckmann
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

using Clutter;
using Meta;

namespace Gala.Plugins.Notify
{
	public class NotificationStack : Actor
	{
		const int ADDITIONAL_MARGIN = 12;

		public signal void animations_changed (bool running);

		public Screen screen { get; construct; }

		int animation_counter = 0;

		public NotificationStack (Screen screen)
		{
			Object (screen: screen);
		}

		construct
		{
			width = Notification.WIDTH + 2 * Notification.MARGIN + ADDITIONAL_MARGIN;
			clip_to_allocation = true;
		}

		public void show_notification (Notification notification)
		{
			if (animation_counter == 0)
				animations_changed (true);

			// raise ourselves when we got something to show
			get_parent ().set_child_above_sibling (this, null);

			// we have a shoot-over on the start of the close animation, which gets clipped
			// unless we make our container a bit wider and move the notifications over
			notification.margin_left = ADDITIONAL_MARGIN;

			notification.destroy.connect (() => {
				update_positions ();
			});

			float height;
			notification.get_preferred_height (Notification.WIDTH, out height, null);
			update_positions (height);

			insert_child_at_index (notification, 0);

			animation_counter++;

			notification.get_transition ("entry").completed.connect (() => {
				if (--animation_counter == 0)
					animations_changed (false);
			});
		}

		void update_positions (float add_y = 0.0f)
		{
			var y = add_y;
			var i = get_n_children ();
			var delay_step = i > 0 ? 150 / i : 0;
			foreach (var child in get_children ()) {
				if (((Notification) child).being_destroyed)
					continue;

				child.save_easing_state ();
				child.set_easing_mode (AnimationMode.EASE_OUT_BACK);
				child.set_easing_duration (200);
				child.set_easing_delay ((i--) * delay_step);

				child.y = y;
				child.restore_easing_state ();

				y += child.height;
			}
		}
	}
}

