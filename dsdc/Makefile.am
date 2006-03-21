
$(PROGRAMS): $(LDEPS)

noinst_HEADERS = dsdc_master.h 
dsdcbin_PROGRAMS = dsdc
dsdc_SOURCES = master.C main.C
#dsdcbin_PROGRAMS = dsdc_master dsdc_slave dsdc_lmgr
#dsdc_master_SOURCES = master.C main.C
#dsdc_slave_SOURCES = master.C main.C
#dsdc_lmgr_SOURCES = master.C main.C

install-exec-hook:
	ln $(dsdcbindir)/dsdc$(EXEEXT) \
                $(dsdcbindir)/dsdc_slave$(EXEEXT)
	ln $(dsdcbindir)/dsdc$(EXEEXT) \
                $(dsdcbindir)/dsdc_master$(EXEEXT)
	ln $(dsdcbindir)/dsdc$(EXEEXT) \
                $(dsdcbindir)/dsdc_lockserver$(EXEEXT)

CLEANFILES = core *.core *~
EXTRA_DIST = .cvsignore
MAINTAINERCLEANFILES = Makefile.in
