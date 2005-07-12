## Process this file with automake to produce Makefile.in
## $Id$


SUBDIRS = libdsdc dsdc tst

#test

EXTRA_DIST = setup autoconf.sed .cvsignore 

CLEANFILES = core *.core *~

MAINTAINERCLEANFILES = 				\
	aclocal.m4 install-sh mkinstalldirs missing depcomp \
	configure config.guess config.sub config.h.in \
	ltconfig ltmain.sh \
	INSTALL COPYING Makefile.in stamp-h.in

BUILT_SOURCES = config.h
DISTCLEANFILES = config.h stamp-auto-h autom4te*.cache

#uninstall-local:
#	-rm -f $(DESTDIR)$(pkglibdir) $(DESTDIR)$(pkgincludedir)
#	-rmdir $(DESTDIR)$(okwslibdir) $(DESTDIR)$(owksincludedir) \
#		$(DESTDIR)$(confdir)

#all-recursive-am: aux-all
#mostlyclean-recursive: aux-mostlyclean
#clean-recursive: aux-clean
#distclean-recursive: aux-distclean
#maintainer-clean-recursive: aux-maintainer-clean

.PHONY: rpcclean
rpcclean:
	for dir in libdsdc; do \
		(cd $$dir && $(MAKE) rpcclean); \
	done
