
#include "dsdc_state.h"
#include "dsdc_const.h"
#include "crypt.h"

void
dsdc_system_state_cache_t::handle_refresh (const dsdc_getstate_res_t &res)
{
  if (res.needupdate) {
    _system_state = *res.slaves;
    sha1_hashxdr (_system_state_hash.base (), _system_state);

    pre_construct ();
    construct_tree ();
    post_construct ();

    clean_cache ();
  } else {
    if ( ++_n_updates_since_clean > dsdcs_clean_interval ) 
      clean_cache ();
  }
}

void
dsdc_system_state_cache_t::construct_tree ()
{
  //_hash_ring.deleteall_correct ();
  _hash_ring.deleteall (); // XXX for time being
  for (u_int i = 0; i < _system_state.slaves.size (); i++) {
    const dsdcx_slave_t &sl = _system_state.slaves[i];
    aclnt_wrap_t *w = new_wrap (sl.hostname, sl.port);
    for (u_int j = 0; j < sl.keys.size (); j++) {
      _hash_ring.insert (New dsdc_ring_node_t (w, sl.keys[j]));
    }
  }
}

dsdc_system_state_cache_t::dsdc_system_state_cache_t ()
  : _n_updates_since_clean (0), 
    _destroyed (New refcounted<bool> (false))
{
  memset (_system_state_hash.base (), 0, _system_state_hash.size ());
}

dsdc_system_state_cache_t::~dsdc_system_state_cache_t ()
{
  *_destroyed = true;
  //_hash_ring.deleteall_correct ();
  _hash_ring.deleteall (); // XXX for the time being
}

void
dsdc_system_state_cache_t::schedule_refresh ()
{
  delaycb (dsdcs_getstate_interval, 0,
	   wrap (this, &dsdc_system_state_cache_t::refresh, _destroyed));
}

void
dsdc_system_state_cache_t::refresh_cb (ptr<bool> df,
				       ptr<dsdc_getstate_res_t> res, 
				       clnt_stat err)
{
  if (*df)
    return;

  if (err) 
    warn << "DSDC_GETSTATE failure: " << err << "\n";
  else
    handle_refresh (*res);
}

void
dsdc_system_state_cache_t::refresh (ptr<bool> df)
{
  if (*df)
    return;

  schedule_refresh ();
  ptr<aclnt> c = get_primary ();
  if (!c) {
    warn << "Cannot find any masters that are alive!\n";
  } else {
    ptr<dsdc_getstate_res_t> res = New refcounted<dsdc_getstate_res_t> ();
    c->call (DSDC_GETSTATE, &_system_state_hash, res,
	     wrap (this, &dsdc_system_state_cache_t::refresh_cb, 
		   _destroyed, res));
  }
}

