#!/bin/sh

#
# $Id$
#

for f in acsfs.m4 acokws.m4 
do
  if test ! -f $f; then
    for d in /usr/local/okws/buildtools \
	     /usr/local/lib/sfslite \
	     /usr/local/share/aclocal \
	     /usr/local/gnu-autotools/shared/aclocal-1.9 
    do
      if test -f $d/$f; then
	  ln -s $d/$f $f
	  break
      fi
    done
  fi
done

PATH=/usr/local/gnu-autotools/bin:$PATH
export PATH

autoreconf -f -i -s
