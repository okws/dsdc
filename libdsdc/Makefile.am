
sfslib_LTLIBRARIES = libdsdc.la

libdsdc_la_SOURCES = dsdc_prot.C dsdc_util.C state.C const.C ring.C \
		     smartcli.C slave.C smartcli_mget.C

sfsinclude_HEADERS = dsdc_prot.h dsdc.h dsdc_ring.h dsdc_const.h \
		     dsdc_prot.x dsdc_util.h dsdc_slave.h dsdc_state.h

dsdc_prot.C: $(srcdir)/dsdc_prot.x dsdc_prot.h
	@rm -f $@
	-$(RPCC) -c $(srcdir)/dsdc_prot.x || rm -f $@

dsdc_prot.h: $(srcdir)/dsdc_prot.x
	@rm -f $@
	-$(RPCC) -h $(srcdir)/dsdc_prot.x || rm -f $@

.PHONY: rpcclean
rpcclean:
	@rm -f dsdc_prot.h dsdc_prot.C

EXTRA_DIST = .cvsignore
CLEANFILES = core *.core *~ *.rpo

MAINTAINERCLEANFILES = Makefile.in config.guess config.h.in config.sub \
	configure install-sh ltconfig ltmain.sh missing mkinstalldirs \
	stamp-h.in 
