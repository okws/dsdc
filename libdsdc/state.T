// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "dsdc_state.h"
#include "dsdc_const.h"
#include "crypt.h"

//-----------------------------------------------------------------------

void
dsdc_system_state_cache_t::change_lock_server_to (aclnt_wrap_t *nl)
{
    if (_lock_server) {
        if (show_debug (DSDC_DBG_LOW))
            warn << "deactivating old lock server: "
            << _lock_server->remote_peer_id () << "\n";
        delete _lock_server;
    }

    _lock_server = nl;

    if (_lock_server && show_debug (DSDC_DBG_LOW))
        warn << "activating new lock server: "
        << _lock_server->remote_peer_id () << "\n";
}

//-----------------------------------------------------------------------

void
dsdc_system_state_cache_t::refresh_lock_server ()
{
    aclnt_wrap_t *nl = NULL;
    if (_system_state.lock_server) {
        if ((nl = new_lockserver_wrap (_system_state.lock_server->hostname,
                                       _system_state.lock_server->port))) {
            if (!_lock_server ||
                nl->remote_peer_id () != _lock_server->remote_peer_id ())
                change_lock_server_to (nl);
            else
                delete nl;
        }
    } else if (_lock_server) {
        // the lock server went down
        change_lock_server_to (NULL);
    }
}

//-----------------------------------------------------------------------

void
dsdc_system_state_cache_t::clear_all ()
{
    if (_system_state.slaves.size ()) {
        dsdc_getstate_res_t res (true);
        handle_refresh (res);
    }
}

//-----------------------------------------------------------------------

void
dsdc_system_state_cache_t::handle_refresh (const dsdc_getstate_res_t &res)
{
    if (res.needupdate) {
        _system_state = *res.state;
        sha1_hashxdr (_system_state_hash.base (), _system_state);

        pre_construct ();
        construct_tree ();
        refresh_lock_server ();
        post_construct ();

        clean_cache ();
    } else {
        if ( ++_n_updates_since_clean > dsdcs_clean_interval )
            clean_cache ();
    }
}

//-----------------------------------------------------------------------

void
dsdc_system_state_cache_t::construct_tree ()
{
    _hash_ring.deleteall_correct ();
    for (u_int i = 0; i < _system_state.slaves.size (); i++) {
        const dsdcx_slave_t &sl = _system_state.slaves[i];
        aclnt_wrap_t *w = new_wrap (sl.hostname, sl.port);
        for (u_int j = 0; j < sl.keys.size (); j++) {
            _hash_ring.insert (New dsdc_ring_node_t (w, sl.keys[j]));
        }
    }
}

//-----------------------------------------------------------------------

dsdc_system_state_cache_t::dsdc_system_state_cache_t ()
        : _n_updates_since_clean (0),
          _destroyed (New refcounted<bool> (false)),
          _lock_server (NULL),
          _loop_running (false)
{
    memset (_system_state_hash.base (), 0, _system_state_hash.size ());
}

//-----------------------------------------------------------------------

dsdc_system_state_cache_t::~dsdc_system_state_cache_t ()
{
    *_destroyed = true;
    _hash_ring.deleteall_correct ();
}

//-----------------------------------------------------------------------

tamed void
dsdc_system_state_cache_t::refresh_loop ()
{
    tvars {
        ptr<bool> df;
    }
    df = _destroyed;

    if (!_loop_running) {
        _loop_running = true; 

        while (!*df) {
            twait { refresh (mkevent ()); } 
            twait { delaycb (dsdcs_getstate_interval, 0, mkevent ()); }
        }
    }
}

//-----------------------------------------------------------------------

tamed void
dsdc_system_state_cache_t::refresh (evv_t::ptr ev)
{
    tvars {
        clnt_stat err;
        ptr<aclnt> c;
        dsdc_getstate_res_t res;
        ptr<bool> df;
    }

    df = _destroyed;
    if (!(c = get_primary ())) {
        warn << "Cannot find any masters that are alive!\n";
        if (clean_on_all_masters_dead ()) {
            clear_all ();
        }
    } else {
        twait { 
            RPC::dsdc_prog_1::dsdc_getstate
                (c, _system_state_hash, &res, mkevent (err));
        }
        if (err) {
            warn << "DSDC_GETSTATE failure: " << err << "\n";
        } else if (!*df) {
            handle_refresh (res);
        }
    }
    if (ev) ev->trigger ();
}

//-----------------------------------------------------------------------

str
dsdc_system_state_cache_t::fingerprint (str *p) const
{
    return _hash_ring.fingerprint (p);
}

//-----------------------------------------------------------------------

