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
command="/disk/dsdc/0.2/shared/bin/dsdc"
dsdc_masters="stage0.okcupid.com stage1.okcupid.com"
dsdc_slave_flags="-s 512M -d 0xffff"
dsdc_slave_flags="-S -q ${dsdc_slave_flags} ${dsdc_masters}"
pidfile="/var/run/dsdc_slave.pid"

load_rc_config $name
run_rc_command "$1"

