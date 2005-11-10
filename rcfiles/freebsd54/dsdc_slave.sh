#!/bin/sh
#
# DSDC rc.d control script
#
# This is a standard rc.d script to control dsdc.  It responds to all
# standard rc.d commands:
#
#   Usage: dsdc_slave [fast|force](start|stop|restart|rcvar|status|poll)
#
# In order for it to work, dsdc_slave_enable="YES" needs to be set in 
# /etc/rc.conf.
#
# Author:  Alfred Perlstein <alfred@okcupid.com>
#
# $Id$
#

. /etc/rc.subr

name="dsdc_slave"
rcvar=`set_rcvar`
load_rc_config $name

if [ "x${dsdc_buildtag}" = "x" ] ; then
	dsdc_buildtag=shared
fi
command="/disk/dsdc/0.2/${dsdc_buildtag}/bin/dsdc"
if [ ! -x ${command} ] ; then
	echo "${name}: unable to exec ${command}"
fi

if [ "x${dsdc_masters}" = "x" ] ; then
	dsdc_masters="stage0.okcupid.com stage1.okcupid.com"
fi

if [ "x${dsdc_slave_cachesize}" = "x" ] ; then
	dsdc_slave_cachesize="512M"
fi
dsdc_slave_flags="-s ${dsdc_slave_cachesize}"

# Debug off.
#dsdc_slave_flags="${dsdc_slave_flags} -d 0xffff"
dsdc_slave_flags="${dsdc_slave_flags} -d 0x01"
dsdc_slave_flags="-S -q ${dsdc_slave_flags} ${dsdc_masters}"

pidfile="/var/run/dsdc_slave.pid"
dir=/disk/coredumps/${name}
cd ${dir}
run_rc_command "$1"
