
$(PROGRAMS): $(LDEPS)

noinst_HEADERS = dsdc_master.h dsdc_slave.h
sfsbin_PROGRAMS = dsdc
dsdc_SOURCES = slave.C master.C main.C

CLEANFILES = core *.core *~
EXTRA_DIST = .cvsignore
MAINTAINERCLEANFILES = Makefile.in
