dnl allow files to be dumped into normal bin directories
dnl
AC_DEFUN([DSDC_SYSTEMBIN],
[AC_ARG_WITH(systembin,
--with-systembin	Install execs to systemwide bin despite tag)
if test "$with_systembin" -a "$with_systembin" != "no"; then
	dsdc_systembin=yes
fi
])

dnl OKJAILDIR
dnl
AC_DEFUN([OKJAILDIR],
[AC_ARG_WITH(jaildir,
--with-jaildir[[=PATH]]	     specify location of jail directory)
if test "$with_jaildir" = yes -o "$with_jaildir" = ""; then
    with_jaildir="/disk/cupjail"
fi
okjaildir="$with_jaildir"
AC_SUBST(okjaildir)
])


dnl
dnl DSDC_MODULE
dnl
AC_DEFUN([DSDC_MODULE],
[
AC_ARG_WITH(module_prefix,
--with-module-prefix=NAME    module install location ('/usr/local' by default))
if test "${with_module_prefix+set}" = "set" ; then
	module_prefix="$with_module_prefix"
else
	module_prefix=/usr/local
fi
module_name=dsdc
AC_SUBST(module_prefix)
AC_SUBST(module_name)
])

dnl
dnl DSDC_PTHREADS
dnl
AC_DEFUN([DSDC_PTHREAD],
[
AC_ARG_ENABLE(pthread,
--enable-pthreads      Enable pthread support)
if test "${enable_pthread+set}" = "set" ; then
      AC_DEFINE(HAVE_DSDC_PTHREAD, 1, DSDC-pthread backend)
      CXXDEBUG="$CXXDEBUG -pthread"           
      DEBUG="$DEBUG -pthread"           
fi      
])
