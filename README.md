# What' this?#

That's my personal build of the window manager [gala](https://code.launchpad.net/~gala-dev/gala/trunk).

# How to compile this?#


Make sure that you removed gala from your system. Running gala during the installation is ok and works fine.

To install this build do:

    ./autogen.sh --prefix='/usr' --disable-schemas-compile
    make
    sudo make install
    sudo glib-compile-schemas /usr/share/glib-2.0/schemas/
    
# What is changed?#

## Keybinding for show-workspace-view ##

You can bind show-workspace-view to a key now. The relevant fixes are:

	=== modified file 'src/WindowManager.vala'
	--- src/WindowManager.vala	2014-08-04 02:10:16 +0000
	+++ src/WindowManager.vala	2014-08-11 13:40:12 +0000
	@@ -127,6 +127,10 @@
	 
	 			/*keybindings*/
	 
	+			screen.get_display ().add_keybinding ("show-workspace-view", KeybindingSettings.get_default ().schema, 0, () => {
	+					perform_action(ActionType.SHOW_WORKSPACE_VIEW);
	+			});
	+
	 			screen.get_display ().add_keybinding ("switch-to-workspace-first", KeybindingSettings.get_default ().schema, 0, () => {
	 				screen.get_workspace_by_index (0).activate (screen.get_display ().get_current_time ());
	 			});

And:

	=== modified file 'data/org.pantheon.desktop.gala.gschema.xml.in.in'
	--- data/org.pantheon.desktop.gala.gschema.xml.in.in	2014-04-19 12:57:09 +0000
	+++ data/org.pantheon.desktop.gala.gschema.xml.in.in	2014-08-10 16:47:07 +0000
	@@ -84,6 +84,11 @@
	 	</schema>
	 	
	 	<schema path="/org/pantheon/desktop/gala/keybindings/" id="org.pantheon.desktop.gala.keybindings" gettext-domain="@GETTEXT_PACKAGE@">
	+        <key type="as" name="show-workspace-view">
	+			<default><![CDATA[['<Super>Enter']]]></default>
	+			<summary></summary>
	+			<description></description>
	+		</key>
	 		<key type="as" name="switch-to-workspace-first">
	 			<default><![CDATA[['<Super>Home']]]></default>
	 			<summary>Shortcut to move to first workspace</summary>

## Multi-monitor hot-corner fix ##

I merged [this](https://code.launchpad.net/~roryj/gala/hotcorners-on-multi-monitors/+merge/218884) fix by Rory J Sanderson, which is not merged to gala/trunk yet. On multi-monitor settings where the resulting screen is still rectangular, the hot-corners are where you expect them to be.
