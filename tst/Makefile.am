-include $(SFS_LIB_MK)

$(PROGRAMS): $(LDEPS)

noinst_PROGRAMS = tst tst2 tst3 tst4 tst5 tstfscache tstfslru fs_stress
tst_SOURCES = tst_prot.C tst.C

tst.o: tst_prot.h
tst.lo: tst_prot.h
tst2.o: tst_prot.h tst2.C
tst2.lo: tst_prot.h tst2.C
tst3.o: tst_prot.h tst3.C
tst3.lo: tst_prot.h tst3.C
tst4.o: tst_prot.h tst4.C
tst4.lo: tst_prot.h tst4.C

tst2_SOURCES = tst2.C tst_prot.C
tst3_SOURCES = tst3.C tst_prot.C
tst4_SOURCES = tst4.C tst_prot.C
tst5_SOURCES = tst5.C tst_prot.C
tstfscache_SOURCES = tstfscache.C
tstfslru_SOURCES = tstfslru.C
fs_stress_SOURCES = fs_stress.C

tst_prot.C: $(srcdir)/tst_prot.x tst_prot.h
	@rm -f $@
	-$(RPCC) -c $(srcdir)/tst_prot.x || rm -f $@

tst_prot.h: $(srcdir)/tst_prot.x
	@rm -f $@
	-$(RPCC) -h $(srcdir)/tst_prot.x || rm -f $@

stress_data: $(srcdir)/gen_stress.py
	python $< 10000 > $@


SUFFIXES = .C .T .h

.T.C:
	$(TAME) -o $@ $< || (rm -f $@ && false)

tstfscache.o:	tstfscache.C
tstfscache.lo:	tstfscache.C
tstfslru.o: tstfslru.C
tstfslru.lo: tstfslru.C
fs_stress.o: fs_stress.C
fs_stress.lo: fs_stress.C

CLEANFILES = core *.core *~ tstfscache.C tstfslru.C fs_stress.C \
	tst2.T tst3.T tst4.T tst5.T
EXTRA_DIST = .cvsignore tstfscache.T tstfslru.T tst2.T tst3.T tst4.T tst5.T
MAINTAINERCLEANFILES = Makefile.in

.PHONY: tameclean

tameclean:
	@rm -f tstfscache.C tstfslru.C fs_stress.C
