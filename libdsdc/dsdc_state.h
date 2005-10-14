// -*-c++-*-
/* $Id$ */

#ifndef _DSDC_STATE_H
#define _DSDC_STATE_H

#include "dsdc_prot.h"
#include "dsdc_ring.h"
#include "arpc.h"

/**
 * a class that caches the global state of the system; included is
 * a mechanism to keep the cached copy of the state up-to-date
 * with respect to known masters.
 *
 */
class dsdc_system_state_cache_t {
protected:
  dsdc_system_state_cache_t ();
  virtual ~dsdc_system_state_cache_t ();

  void construct_tree ();
  virtual void clean_cache () {}
  virtual ptr<aclnt> get_primary () = 0;
  virtual aclnt_wrap_t *new_wrap (const str &h, int p) = 0;
  virtual aclnt_wrap_t *new_lockserver_wrap (const str &h, int p) = 0;

  virtual void pre_construct () {}
  virtual void post_construct () {}

  void handle_refresh (const dsdc_getstate_res_t &r);
  void refresh_cb (ptr<bool> df, ptr<dsdc_getstate_res_t> r, clnt_stat err);
  void refresh (ptr<bool> df);
  void schedule_refresh ();

  void refresh_lock_server ();
  void change_lock_server_to (aclnt_wrap_t *nl);

  dsdcx_state_t  _system_state;
  dsdc_key_t _system_state_hash;
  u_int _n_updates_since_clean;
  dsdc_hash_ring_t _hash_ring;
  ptr<bool> _destroyed;
  aclnt_wrap_t *_lock_server;
};


#endif
