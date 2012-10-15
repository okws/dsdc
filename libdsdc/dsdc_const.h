
#include "async.h"
#include "tame.h"

#pragma once

extern int dsdc_heartbeat_interval;
extern int dsdcs_getstate_interval;

extern int dsdc_missed_beats_to_death;
extern int dsdc_port;
extern int dsdc_proxy_port;
extern int dsdc_slave_port;
extern int dsdc_retry_wait_time;
extern u_int dsdc_rpc_timeout;

extern u_int dsdc_slave_nnodes;
extern size_t dsdc_slave_maxsz;

extern u_int dsdc_packet_sz;
extern u_int dsdcs_port_attempts;
extern u_int dsdcl_default_timeout;

extern time_t dsdci_connect_timeout_ms;
extern time_t dsdcm_timer_interval;
extern int dsdc_aiod2_remote_port;

extern size_t dsdcs_clean_batch;
extern time_t dsdcs_clean_wait_us;

typedef event<int,str>::ref evis_t;
