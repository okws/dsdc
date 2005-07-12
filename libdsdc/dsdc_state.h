// -*-c++-*-
/* $Id$ */

#ifndef _DSDC_STATE_H
#define _DSDC_STATE_H

#include "dsdc_prot.h"
#include "dsdc_ring.h"
#include "arpc.h"

class dsdc_system_state_cache_t {
protected:
  dsdc_system_state_cache_t ();
  virtual ~dsdc_system_state_cache_t ();

  void construct_tree ();
  virtual void clean_cache () {}
  virtual ptr<aclnt> get_primary () = 0;
  virtual aclnt_wrap_t *new_wrap (const str &h, int p) = 0;

  virtual void pre_construct () {}
  virtual void post_construct () {}

  void handle_refresh (const dsdc_getstate_res_t &r);
  void refresh_cb (ptr<bool> df, ptr<dsdc_getstate_res_t> r, clnt_stat err);
  void refresh (ptr<bool> df);
  void schedule_refresh ();

  dsdcx_slaves_t  _system_state;
  dsdc_key_t _system_state_hash;
  u_int _n_updates_since_clean;
  dsdc_hash_ring_t _hash_ring;
  ptr<bool> _destroyed;
};


#endif
