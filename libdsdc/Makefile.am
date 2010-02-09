
-include $(SFS_LIB_MK)

dsdclib_LTLIBRARIES = libdsdc.la

if DSDC_NO_CUPID
libdsdc_la_SOURCES = dsdc_prot.C dsdc_util.C state.C const.C ring.C \
		     smartcli.C smartcli_mget.C lock.C slave.C \
			stats.C fscache.C fslru.C stats1.C \
			stats2.C thback.C

dsdcinclude_HEADERS = dsdc_prot.h dsdc.h dsdc_ring.h dsdc_const.h \
		     dsdc_util.h dsdc_slave.h dsdc_state.h \
                     dsdc_lock.h qanswer_aux.h  dsdc_stats.h dsdc_signal.h \
			fscache.h fslru.h dsdc_format.h \
			dsdc_stats1.h dsdc_stats2.h dsdc_tamed.h
else
libdsdc_la_SOURCES = dsdc_prot.C dsdc_util.C state.C const.C ring.C \
		     smartcli.C smartcli_mget.C match.C lock.C \
		     slave.C stats.C fscache.C fslru.C stats1.C \
			stats2.C thback.C

dsdcinclude_HEADERS = dsdc_prot.h dsdc.h dsdc_ring.h dsdc_const.h \
		     dsdc_util.h dsdc_slave.h dsdc_state.h \
                     dsdc_lock.h qanswer_aux.h \
		     dsdc_match.h dsdc_stats.h dsdc_signal.h fscache.h \
			dsdc_format.h dsdc_stats2.h dsdc_tamed.h
endif


libdsdc_la_LDFLAGS = $(LIBTOOL_VERSION_INFO)

SUFFIXES = .C .T .h .Th

.T.C:
	$(TAME) -o $@~ $< && (mv -f $@~ $@)

.Th.h:
	$(TAME) -o $@~ $< && (mv -f $@~ $@)


slave.o:	slave.C
slave.lo:	slave.C
smartcli.o:	smartcli.C
smartcli.lo:	smartcli.C
fscache.o:	fscache.C 
fscache.lo:	fscache.C
fslru.o:	fslru.h
fslru.lo:	fslru.h
smartcli.o:	dsdc_tamed.h
smartcli.lo:	dsdc_tamed.h

#userid_prot.x userid_prot.h

dsdc_prot.C: $(srcdir)/dsdc_prot.x dsdc_prot.h
	@rm -f $@
	-$(RPCC) -c $(srcdir)/dsdc_prot.x || rm -f $@

dsdc_prot.h: $(srcdir)/dsdc_prot.x
	@rm -f $@
	-$(RPCC) -h $(srcdir)/dsdc_prot.x || rm -f $@

.PHONY: rpcclean tameclean
rpcclean:
	@rm -f dsdc_prot.h dsdc_prot.C

tameclean:
	@rm -f smartcli.C fscache.C fslru.h dsdc_tamed.h

EXTRA_DIST = .cvsignore smartcli.T fscache.T fslru.Th dsdc_tamed.Th
CLEANFILES = core *.core *~ *.rpo

MAINTAINERCLEANFILES = Makefile.in config.guess config.h.in config.sub \
	configure install-sh ltconfig ltmain.sh missing mkinstalldirs \
	stamp-h.in 
