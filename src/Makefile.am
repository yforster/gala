include $(top_srcdir)/Makefile.common

VAPIDIR = $(top_srcdir)/vapi

gala_VALAFLAGS = \
	$(GALA_CORE_VALAFLAGS) \
	$(top_builddir)/lib/gala.vapi \
	--vapidir $(VAPIDIR) \
	$(VAPIDIR)/config.vapi \
	$(VAPIDIR)/cogl-fixes.vapi \
	$(NULL)

galadir = $(bindir)

BUILT_SOURCES = gala_vala.stamp

gala_PROGRAMS = gala

gala_CFLAGS = \
	$(GALA_CORE_CFLAGS) \
	-include config.h \
	-w \
	-DGNOME_DESKTOP_USE_UNSTABLE_API \
	-I$(top_builddir)/lib \
	$(NULL)

gala_LDADD = \
	-lm \
	$(GALA_CORE_LIBS) \
	$(top_builddir)/lib/libgala.la \
	$(NULL)

gala_VALASOURCES = \
	DBus.vala \
	DragDropAction.vala \
	InternalUtils.vala \
	Main.vala \
	PluginManager.vala \
	ScreenSaver.vala \
	Settings.vala \
	ShadowEffect.vala \
	TextShadowEffect.vala \
	WindowListener.vala \
	WindowManager.vala \
	WorkspaceManager.vala \
	Background/Background.vala \
	Background/BackgroundCache.vala \
	Background/BackgroundManager.vala \
	Background/SlideShow.vala \
	Background/SystemBackground.vala \
	Widgets/IconGroup.vala \
	Widgets/IconGroupContainer.vala \
	Widgets/MonitorClone.vala \
	Widgets/MultitaskingView.vala \
	Widgets/WindowClone.vala \
	Widgets/WindowCloneContainer.vala \
	Widgets/WindowOverview.vala \
	Widgets/WindowSwitcher.vala \
	Widgets/WorkspaceClone.vala \
	$(NULL)

nodist_gala_SOURCES = \
	gala_vala.stamp \
	$(gala_VALASOURCES:.vala=.c) \
	$(NULL)

gala_vala.stamp: $(gala_VALASOURCES)
	$(AM_V_VALA)$(VALAC) \
		$(gala_VALAFLAGS) \
		--basedir $(srcdir) \
		--directory $(builddir) \
		-C \
		$(filter %.vala %.c,$^)
	$(AM_V_at)touch $@

CLEANFILES = \
	$(nodist_gala_SOURCES) \
	$(NULL)

EXTRA_DIST = \
	$(gala_VALASOURCES) \
	$(NULL)

