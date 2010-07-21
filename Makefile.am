## Process this file with automake to produce Makefile.in
## $Id$


SUBDIRS = libdsdc dsdc tst

EXTRA_DIST = setup .cvsignore setup.gnu

CLEANFILES = core *.core *~

MAINTAINERCLEANFILES = 				\
	aclocal.m4 install-sh mkinstalldirs missing depcomp \
	configure config.guess config.sub config.h.in \
	ltconfig ltmain.sh \
	INSTALL COPYING Makefile.in stamp-h.in

BUILT_SOURCES = config.h
DISTCLEANFILES = config.h stamp-auto-h autom4te*.cache

install-exec-local:
	-src=$(dsdclinkto); dst=$(dsdclinkfrom); \
	rm -f $$dst; \
	if test "`dirname $$src`" = "`dirname $$dst`"; then \
		ln -s "`basename $$src`" $$dst; \
	else \
		ln -s $$src $$dst; \
	fi

#uninstall-local:
#	-rm -f $(DESTDIR)$(pkglibdir) $(DESTDIR)$(pkgincludedir)
#	-rmdir $(DESTDIR)$(okwslibdir) $(DESTDIR)$(owksincludedir) \
#		$(DESTDIR)$(confdir)

#all-recursive-am: aux-all
#mostlyclean-recursive: aux-mostlyclean
#clean-recursive: aux-clean
#distclean-recursive: aux-distclean
#maintainer-clean-recursive: aux-maintainer-clean

##
## New aclocal (1.10+) is asking for this...
##
ACLOCAL_AMFLAGS = -I m4

.PHONY: rpcclean tameclean
rpcclean:
	for dir in libdsdc; do \
		(cd $$dir && $(MAKE) rpcclean); \
	done

tameclean:
	for dir in $(SUBDIRS) ; do \
		(cd $$dir && $(MAKE) tameclean); \
	done
