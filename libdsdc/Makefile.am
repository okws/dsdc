
dsdclib_LTLIBRARIES = libdsdc.la

if DSDC_NO_CUPID
libdsdc_la_SOURCES = dsdc_prot.C dsdc_util.C state.C const.C ring.C \
		     smartcli.C smartcli_mget.C lock.C slave.C \
			stats.C

dsdcinclude_HEADERS = dsdc_prot.h dsdc.h dsdc_ring.h dsdc_const.h \
		     dsdc_util.h dsdc_slave.h dsdc_state.h \
                     dsdc_lock.h qanswer_aux.h  dsdc_stats.h dsdc_signal.h
else
libdsdc_la_SOURCES = dsdc_prot.C dsdc_util.C state.C const.C ring.C \
		     smartcli.C smartcli_mget.C match.C lock.C \
		     slave.C stats.C

dsdcinclude_HEADERS = dsdc_prot.h dsdc.h dsdc_ring.h dsdc_const.h \
		     dsdc_util.h dsdc_slave.h dsdc_state.h \
                     dsdc_lock.h qanswer_aux.h \
		     dsdc_match.h dsdc_stats.h dsdc_signal.h
endif

SUFFIXES = .C .T .h

.T.C:
	-$(TAME) -o $@ $< || rm -f $@

smartcli.o:	smartcli.C
smartcli.lo:	smartcli.C

#userid_prot.x userid_prot.h

dsdc_prot.C: $(srcdir)/dsdc_prot.x dsdc_prot.h
	@rm -f $@
	-$(RPCC) -c $(srcdir)/dsdc_prot.x || rm -f $@

dsdc_prot.h: $(srcdir)/dsdc_prot.x
	@rm -f $@
	-$(RPCC) -h $(srcdir)/dsdc_prot.x || rm -f $@

#userid_prot.C: $(srcdir)/userid_prot.x userid_prot.h
#@rm -f $@
#-$(RPCC) -c $(srcdir)/userid_prot.x || rm -f $@

#userid_prot.h: $(srcdir)/userid_prot.x
#@rm -f $@
#-$(RPCC) -h $(srcdir)/userid_prot.x || rm -f $@

.PHONY: rpcclean tameclean
rpcclean:
	@rm -f dsdc_prot.h dsdc_prot.C

tameclean:
	@rm -f $(srcdir)/smartcli.C

#@rm -f userid_prot.h userid_prot.C

EXTRA_DIST = .cvsignore smartcli.T
CLEANFILES = core *.core *~ *.rpo

MAINTAINERCLEANFILES = Makefile.in config.guess config.h.in config.sub \
	configure install-sh ltconfig ltmain.sh missing mkinstalldirs \
	stamp-h.in 
