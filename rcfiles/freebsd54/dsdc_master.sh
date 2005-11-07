#!/bin/sh
#
# DSDC rc.d control script
#
# This is a standard rc.d script to control dsdc.  It responds to all
# standard rc.d commands:
#
#   Usage: dsdcmaster.sh [fast|force](start|stop|restart|rcvar|status|poll)
#
# In order for it to work, dsdcmaster_enable="YES" needs to be set in 
# /etc/rc.conf.
#
# Author:  Alfred Perlstein <alfred@okcupid.com>
#
# $Id$
#

. /etc/rc.subr

name="dsdc_master"
rcvar=`set_rcvar`
command="/disk/dsdc/0.2/shared/bin/dsdc"
dsdc_master_flags="-M -q -d 0xffff"
pidfile="/var/run/dsdc_master.pid"
#required_files="/etc/sfs/okws_config"
#extra_command="reload"

load_rc_config $name
run_rc_command "$1"

