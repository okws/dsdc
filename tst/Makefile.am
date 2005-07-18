
$(PROGRAMS): $(LDEPS)

noinst_PROGRAMS = tst tst2 tst3
tst_SOURCES = tst_prot.C tst.C

tst2_SOURCES = tst2.C tst_prot.C
tst3_SOURCES = tst3.C tst_prot.C


tst_prot.C: $(srcdir)/tst_prot.x tst_prot.h
	@rm -f $@
	-$(RPCC) -c $(srcdir)/tst_prot.x || rm -f $@

tst_prot.h: $(srcdir)/tst_prot.x
	@rm -f $@
	-$(RPCC) -h $(srcdir)/tst_prot.x || rm -f $@


CLEANFILES = core *.core *~
EXTRA_DIST = .cvsignore
MAINTAINERCLEANFILES = Makefile.in
