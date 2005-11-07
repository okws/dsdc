
$(PROGRAMS): $(LDEPS)

noinst_HEADERS = dsdc_master.h 
dsdcbin_PROGRAMS = dsdc
dsdc_SOURCES = master.C main.C
#dsdcbin_PROGRAMS = dsdc_master dsdc_slave dsdc_lmgr
#dsdc_master_SOURCES = master.C main.C
#dsdc_slave_SOURCES = master.C main.C
#dsdc_lmgr_SOURCES = master.C main.C

CLEANFILES = core *.core *~
EXTRA_DIST = .cvsignore
MAINTAINERCLEANFILES = Makefile.in
