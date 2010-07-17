
#include "dsdc_const.h"
#include "dsdc_prot.h"

int dsdcs_getstate_interval = 60;      // every minute
int dsdc_heartbeat_interval = 4;       // every 2 seconds
int dsdc_missed_beats_to_death = 10;   // miss 10 beats->death
int dsdc_port = DSDC_DEFAULT_PORT;     // same as RPC progno!
int dsdc_slave_port = 41000;           // slaves also need a port to listen on
int dsdc_retry_wait_time = 10;         // time to wait before retrying
u_int dsdcs_clean_interval = 120;      // force a clean at least every 2 hours

u_int dsdc_slave_nnodes = 5;           // default number of nodes in key ring
size_t dsdc_slave_maxsz = (0x10 << 20); // default max size in bytes (16MB)
u_int dsdc_packet_sz = 0x100000;       // allow big packets!
u_int dsdcs_port_attempts = 100;       // number of ports to try

u_int dsdcl_default_timeout = 10;      // by def, hold locks for 10 seconds
u_int dsdc_rpc_timeout = 3;            // in seconds before calling off an RPC

time_t dsdci_connect_timeout_ms = 1000; // wait for a connect for 1s

