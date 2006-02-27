#!/bin/sh

#
# $Id$
#

#
# Recommended args:
#
#	 -f -i -s

PATH=/usr/local/gnu-autotools/bin:$PATH
export PATH

autoreconf -f -i -s $*
