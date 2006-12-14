
$(PROGRAMS): $(LDEPS)

noinst_PROGRAMS = tst tst2 tst3 tst4 tst5 tstfscache
tst_SOURCES = tst_prot.C tst.C

tst.o: tst_prot.h
tst.lo: tst_prot.h

tst2_SOURCES = tst2.C tst_prot.C
tst3_SOURCES = tst3.C tst_prot.C
tst4_SOURCES = tst4.C tst_prot.C
tst5_SOURCES = tst5.C tst_prot.C
tstfscache_SOURCES = tstfscache.C

tst_prot.C: $(srcdir)/tst_prot.x tst_prot.h
	@rm -f $@
	-$(RPCC) -c $(srcdir)/tst_prot.x || rm -f $@

tst_prot.h: $(srcdir)/tst_prot.x
	@rm -f $@
	-$(RPCC) -h $(srcdir)/tst_prot.x || rm -f $@


SUFFIXES = .C .T .h

.T.C:
	-$(TAME) -o $@ $< || rm -f $@

tstfscache.o:	tstfscache.C
tstfscache.lo:	tstfscache.C

CLEANFILES = core *.core *~ tstfscache.C
EXTRA_DIST = .cvsignore tstfscache.T
MAINTAINERCLEANFILES = Makefile.in

.PHONY: tameclean

tameclean:
	@rm -f tstfscache.C
