Make sure that you removed gala from your system. Running gala during the installation is ok and works fine.

To install this build do:

    ./autogen.sh --prefix='/usr' --disable-schemas-compile
    make
    sudo make install
    sudo glib-compile-schemas /usr/share/glib-2.0/schemas/
    

The interesting modifications are:

For file src/WindowManager.vala add this to the keybindings (search for the comment):

	screen.get_display ().add_keybinding ("show-workspace-view", 
	   KeybindingSettings.get_default ().schema, 0, () => {
					perform_action(ActionType.SHOW_WORKSPACE_VIEW);
		});
		
		
For file data/org.pantheon.desktop.gala.gschema.xml.in.in add this to the keybindings (should be the seconds section):


    <key type="as" name="show-workspace-view">
			<default><![CDATA[['<Super>Enter']]]></default>
			<summary></summary>
			<description></description>
		</key>
