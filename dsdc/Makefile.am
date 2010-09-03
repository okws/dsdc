-include $(SFS_LIB_MK)

$(PROGRAMS): $(LDEPS)

noinst_HEADERS = dsdc_master.h 
dsdcexecbin_PROGRAMS = dsdc dsdc-admin aiod2
dsdc_SOURCES = master.C main.C
dsdc_admin_SOURCES = admin.C output.C
aiod2_SOURCES = aiod2.C
#dsdcbin_PROGRAMS = dsdc_master dsdc_slave dsdc_lmgr
#dsdc_master_SOURCES = master.C main.C
#dsdc_slave_SOURCES = master.C main.C
#dsdc_lmgr_SOURCES = master.C main.C

SUFFIXES = .C .T .h

.T.C:
	-$(TAME) -o $@ $< || rm -f $@

master.o:	master.C
master.lo:	master.C
admin.o:	admin.C
admin.lo:	admin.C
aiod2.lo:	aiod2.C

install-exec-hook:
	ln -f $(dsdcexecbindir)/dsdc$(EXEEXT) \
                $(dsdcexecbindir)/dsdc_slave$(EXEEXT)
	ln -f $(dsdcexecbindir)/dsdc$(EXEEXT) \
                $(dsdcexecbindir)/dsdc_master$(EXEEXT)
	ln -f $(dsdcexecbindir)/dsdc$(EXEEXT) \
                $(dsdcexecbindir)/dsdc_lockserver$(EXEEXT)

CLEANFILES = core *.core *~
EXTRA_DIST = .cvsignore master.T admin.T
MAINTAINERCLEANFILES = Makefile.in

.PHONY: tameclean

tameclean:
	@rm -f master.C admin.C
