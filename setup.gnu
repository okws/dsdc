#!/bin/bash

#
# $Id$
#

if [[ "${SFS_ACLOCAL_PATH:+set}" == "set" ]]; then
    IFS=':' read -ra M4_PATH <<< "${SFS_ACLOCAL_PATH}"
else
    declare -a M4_PATH
fi

for f in acsfs.m4 acokws.m4 
do
  for d in "${M4_PATH[@]}" \
	     /usr/local/okws/buildtools \
	     /usr/local/lib/sfslite \
	     /usr/local/lib/sfslite-1.2 \
	     /usr/local/share/aclocal \
	     /usr/local/gnu-autotools/shared/aclocal-1.9 
    do
      if test -f $d/$f; then
	  ln -sf $d/$f $f
	  break
      fi
  done
done

PATH=/usr/local/gnu-autotools/bin:$PATH
export PATH

autoreconf -f -i -s
