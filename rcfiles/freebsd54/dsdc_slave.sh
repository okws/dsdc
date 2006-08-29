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

command="/disk/dsdc/0.3/${dsdc_buildtag}/bin/dsdc_slave"
if [ ! -x ${command} ] ; then
	echo "${name}: unable to exec ${command}"
fi

dsdc_slave_flags="-S -q ${dsdc_slave_flags} ${dsdc_masters}"

dir=/disk/coredumps/${name}
cd ${dir}

case "$1" in
	start)
		if [ "x${dsdc_slave_instances}" = "x" ] ; then
			${dsdc_slave_instances}=1
		fi
		for i in $(jot ${dsdc_slave_instances}) ; do
			pidfile="/var/run/${name}-${i}.pid"
			run_rc_command "$1"
		done
		;;
	stop)
		echo "Stopping ${name}."
		pkill ${name}
		;;
	*)
		echo "$1 isn't supported"
		;;
esac

