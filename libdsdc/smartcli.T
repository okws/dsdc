// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-
/* $Id$ */

#include "dsdc.h"
#include "dsdc_const.h"

//-----------------------------------------------------------------------

dsdci_srv_t::dsdci_srv_t (const str &h, int p)
        : _key (strbuf ("%s:%d", h.cstr (), p)),
          _hostname (h),
          _port (p),
          _fd (-1),
          _destroyed (New refcounted<bool> (false)),
          _conn_state (CONN_NONE),
          _orphaned (false)
{}

//-----------------------------------------------------------------------

dsdci_srv_t::~dsdci_srv_t ()
{
    *_destroyed = true;
}

//-----------------------------------------------------------------------

void
dsdci_srv_t::hit_eof (ptr<bool> df)
{
    if (*df)
        return;

    if (show_debug (DSDC_DBG_LOW))
        warn << "EOF from remote peer: " << key () << "\n";

    _fd = -1;
    _cli = NULL;
    _x = NULL;

    eof_hook ();
}

//-----------------------------------------------------------------------

void
dsdci_retry_srv_t::eof_hook ()
{
    retry_loop ();
}

//-----------------------------------------------------------------------

bool
dsdc_smartcli_t::add_master (const str &m)
{
    str hostname = "127.0.0.1";
    int port = dsdc_port;
    if (!parse_hn (m, &hostname, &port))
        return false;
    return add_master (hostname, port);
}

//-----------------------------------------------------------------------

bool
dsdc_smartcli_t::add_master (const str &hostname, int port)
{
    ptr<dsdci_master_t> m = New refcounted<dsdci_master_t> (hostname, port);
    bool ret;
    if (_masters_hash[m->key ()]) {
        warn << "duplicate master ignored: " << m->key () << "\n";
        ret = false;
    } else {
        _masters_hash.insert (m);
        _masters.insert_tail (m);
        m->hold ();
        ret = true;
    }
    return ret;
}

//-----------------------------------------------------------------------------

bool 
dsdc_smartcli_t::add_proxy(const str& hostname, int port) {
    _proxies.push_back(New refcounted<dsdci_proxy_t>
                       (hostname, (port < 0 ? dsdc_proxy_port : port)));
    return true;
}

//-----------------------------------------------------------------------

dsdc_smartcli_t::~dsdc_smartcli_t ()
{
    _masters_hash.clear ();
    dsdci_master_t *m;
    while ((m = _masters.first)) {
        _masters.remove (m);
        m->release ();
    }
        
    _slaves_hash.clear ();
    dsdci_slave_t *s;
    while ((s = _slaves.first)) {
        _slaves.remove (s);
        s->release ();
    }
}

//-----------------------------------------------------------------------

ptr<aclnt>
dsdc_smartcli_t::get_primary ()
{
    if (! _masters.first )
        return NULL;

    if (!_curr_master)
        _curr_master = _masters.first ;

    dsdci_master_t *end = NULL;
    for ( ; _curr_master != end;
          _curr_master =
              _masters.next (_curr_master) ?
              _masters.next (_curr_master) : _masters.first) {

        if (!end)
            end = _curr_master;

        if (! _curr_master->is_dead ())
            return _curr_master->get_aclnt ();
    }
    return NULL;
}

//-----------------------------------------------------------------------

bool
dsdci_srv_t::is_dead ()
{
    if (_fd < 0)
        return true;

    if (!_x || _x->ateof ()) {
        hit_eof (_destroyed);
        return true;
    }
    return false;
}

//-----------------------------------------------------------------------

void
dsdc_smartcli_t::pre_construct ()
{
    _slaves_hash_tmp.clear ();
}

//-----------------------------------------------------------------------

ptr<aclnt_wrap_t>
dsdc_smartcli_t::new_lockserver_wrap (const str &h, int p)
{
    return New refcounted<dsdci_slave_t> (h, p);
}

//-----------------------------------------------------------------------

ptr<aclnt_wrap_t>
dsdc_smartcli_t::new_wrap (const str &h, int p)
{
    ptr<dsdci_slave_t> s = New refcounted<dsdci_slave_t> (h, p);
    ptr<dsdci_slave_t> ret = NULL;
    dsdci_slave_t *slave_p;
    if ((slave_p = _slaves_hash[s->key ()])) {
        // already there; no need to jostle the tree at all
        ret = mkref (slave_p);
        s = NULL;
    } else {
        _slaves_hash.insert (s);
        _slaves.insert_head (s);
        s->hold (); // whenever inserting, incref!
        ret = s;
    }

    if (_slaves_hash_tmp[ret->key ()]) {
        warn << "doubly-allocated slave: " << ret->key () << "\n";
    } else {
        _slaves_hash_tmp.insert (ret->key ());
    }

    return ret;
}

//-----------------------------------------------------------------------

void
dsdc_smartcli_t::post_construct ()
{
    dsdci_slave_t *n;
    for (dsdci_slave_t *s = _slaves.first; s; s = n) {
        n = _slaves.next (s);
        if (! _slaves_hash_tmp[s->key ()]) {
            if (show_debug (DSDC_DBG_MED)) {
                warn << "CLEAN: removing slave: " << s->key () << "\n";
            }
            _slaves.remove (s);
            _slaves_hash.remove (s);
            s->release (); // when removing, delete by refcount dec'ing
        }
    }

    // Only on initialization do we need to do this.  We delay return to
    // the caller until after we've initialized the hash ring via
    // the standard state refresh mechanism.
    if (_poke_after_refresh) {
        evv_t ev = _poke_after_refresh;
        _poke_after_refresh = NULL;
        ev->trigger ();
    }
}

//-----------------------------------------------------------------------

str
dsdc_smartcli_t::which_slave (const dsdc_key_t &k)
{
    dsdc_ring_node_t *n;
    str res;
    aclnt_wrap_t *aw;
    if ((n = _hash_ring.successor (k)) && (aw = n->get_aclnt_wrap ())) {
        res = aw->remote_peer_id ();
    }
    return res;
}

//-----------------------------------------------------------------------

tamed void
dsdc_smartcli_t::get (ptr<dsdc_key_t> k, dsdc_get_res_cb_t cb,
                      bool safe, int time_to_expire,
                      const annotation_t *a)
{
    tvars {
        ptr<aclnt> cli;
        dsdc_ring_node_t *n;
        ptr<dsdc_get_res_t> res (New refcounted<dsdc_get_res_t> (DSDC_OK));
        bool tried (false);
        dsdc_get3_arg_t arg3;
        dsdc_req_t arg2;
        clnt_stat err;
        ptr<dsdci_proxy_t> prx;
    }

    if (safe) {
        cli = get_primary ();
    } else if (_proxies.size() && (prx = get_proxy())) {
        twait { prx->get_aclnt(mkevent(cli)); }
    } else {
        if ((n = _hash_ring.successor (*k))) {
            tried = true;
            twait { n->get_aclnt_wrap ()->get_aclnt (mkevent (cli)); }
        }
    }

    if (cli) {

        if (a) {
            arg3.key = *k;
            arg3.time_to_expire = time_to_expire;
            annotation_t::to_xdr (a, &arg3.annotation);
            twait { rpc_call (cli, DSDC_GET3, &arg3, res, mkevent (err)); }

        } else {
            // Use compatibility RPC if not using annotation
            // features.
            arg2.key = *k;
            if (time_to_expire < 0)
                time_to_expire = INT_MAX;
            arg2.time_to_expire = time_to_expire;
            twait { rpc_call (cli, DSDC_GET2, &arg2, res, mkevent (err)); }
        }

        if (err) {
            if (show_debug (DSDC_DBG_LOW)) {
                warn << "lookup failed with RPC error: " << err << "\n";
            }
            res->set_status (DSDC_RPC_ERROR);
            *res->err = err;
        }
    } else {
        res->set_status (tried ? DSDC_DEAD : DSDC_NONODE);
    }
    (*cb) (res);
}

//-----------------------------------------------------------------------

void
dsdc_smartcli_t::put (ptr<dsdc_put3_arg_t> arg, cbi::ptr cb, bool safe)
{
    change_cache<dsdc_put3_arg_t> (arg->key, arg, int (DSDC_PUT3), cb, safe);
}

//-----------------------------------------------------------------------

void
dsdc_smartcli_t::put (ptr<dsdc_put4_arg_t> arg, cbi::ptr cb, bool safe)
{
    change_cache<dsdc_put4_arg_t> (arg->key, arg, int (DSDC_PUT4), cb, safe);
}

//-----------------------------------------------------------------------

void
dsdc_smartcli_t::put (ptr<dsdc_put_arg_t> arg, cbi::ptr cb, bool safe)
{
    change_cache<dsdc_put_arg_t> (arg->key, arg, int (DSDC_PUT), cb, safe);
}

//-----------------------------------------------------------------------

void
dsdc_smartcli_t::remove (ptr<dsdc_key_t> key, cbi::ptr cb, bool safe)
{
    change_cache<dsdc_key_t> (*key, key, int (DSDC_REMOVE), cb, safe);
}

//-----------------------------------------------------------------------

void
dsdc_smartcli_t::remove (ptr<dsdc_remove3_arg_t> arg, cbi::ptr cb, bool safe)
{
    change_cache (arg->key, arg, int (DSDC_REMOVE3), cb, safe);
}

//-----------------------------------------------------------------------

void
dsdc_smartcli_t::rpc_call (ptr<aclnt> cli,
                           u_int32_t procno, const void *in, void *out,
                           aclnt_cb cb)
{
    if (_timeout > 0) {
        cli->timedcall (_timeout, 0, procno, in, out, cb);
    } else {
        cli->call (procno, in, out, cb);
    }
}

//-----------------------------------------------------------------------

tamed void
dsdci_srv_t::connect (cbb cb)
{
    tvars { 
        bool ret (true);
        int f;
        ptr<bool> df;
    }
    
    df = _destroyed;

    if (!is_dead ()) { 
        ret = true;
    } else {
        twait { tcpconnect (_hostname, _port, mkevent (f)); }

        if (*df) {
            ret = false;
        } else if ((_fd = f) < 0) {
            if (show_debug (DSDC_DBG_LOW)) {
                warn << "connection to " << typ () << " failed: " 
                     << key () << "\n";
            }
            ret = false;
        } else {
            if (show_debug (DSDC_DBG_MED)) {
                warn << "connection to " << typ () << " succeeded: " 
                     << key () << "\n";
            }
            assert ((_x = axprt_stream::alloc (_fd, dsdc_packet_sz)));
            _cli = aclnt::alloc (_x, dsdc_prog_1);
            _cli->seteofcb (wrap (this, &dsdci_srv_t::hit_eof, _destroyed));
        }
    }
    (*cb) (ret);
}

//-----------------------------------------------------------------------

void
dsdci_srv_t::trigger_waiters ()
{
    while (_waiters.size ()) {
        evv_t e = _waiters.pop_back ();
        e->trigger ();
    }
}

//-----------------------------------------------------------------------

tamed void
dsdci_srv_t::get_aclnt (aclnt_cb_t cb)
{
    tvars {
        ptr<bool> df;
        ptr<aclnt> ret;
        bool triggered (false);
        rendezvous_t<bool> rv (__FILE__, __LINE__);
        timecb_t *tcb (NULL);
        bool ok;
        bool timeout;
        ptr<dsdci_srv_t> hold;
    }

    hold = mkref (this);
    df = _destroyed;
  
    if (!is_dead () && _cli) { /* noop, see below */ }

    else if (_conn_state == CONN_NONE) {

        // Only one "thread" should try to connect at a time!
        // Before the timeout, we're in "connection fast" mode, meaning
        // that others might want to wait for us.
        _conn_state = CONN_FAST;

        // Connect, but keep in mind that connecting might take forever.
        connect (mkevent (rv, false, ok));
        tcb = delaycb (dsdci_connect_timeout_ms / 1000, 
                       dsdci_connect_timeout_ms * 1000000, 
                       mkevent (rv, true));

        twait (rv, timeout);

        // We didn't connect in time, that means we're in slow state
        if (timeout) { _conn_state = CONN_SLOW; }

        // tell the other guys right away, regardless of whether it
        // worked or if if was a timeout.
        trigger_waiters ();

        if (timeout) {
            tcb = NULL;
            (*cb) (NULL);
            triggered = true;

            if (show_debug (DSDC_DBG_LOW)) {
                warn << "Connection to " << typ () << " "
                     << key () << " did not complete in time! "
                     << "Will continue connection in the background\n";
            }

            // Now wait for the connection to complete, which can take
            // as long as it needs to, but we need not worry that anyone
            // is waiting for it.
            twait (rv, ok);

        } else {
           
            // In this case, the dangling timer ought to be removed.
            if (tcb) timecb_remove (tcb);
            rv.cancel (); 
        }

        _conn_state = CONN_NONE;

    } else if (_conn_state == CONN_FAST) {

        // Only wait for a connection to finish if it's before the timeout;
        // Otherwise, assume it's a lost cause and bail out.
        twait { _waiters.push_back (mkevent ()); }
    }

    if (!triggered) {
        if (!is_dead ()) { ret = _cli; }
        (*cb) (ret); 
    }
}

//-----------------------------------------------------------------------

tamed void
dsdc_smartcli_t::master_connect (dsdci_master_t *m, evi_t ev)
{
    tvars {
        bool ok (false);
        int rc (-1);
    }

    twait { m->connect (mkevent (ok)); }
    
    if (!ok) {

        rc = -1;

        // Keep attempting to retry in the background, so that eventually
        // this thing might work...
        if (_opts & DSDC_RETRY_ON_STARTUP) {
            m->retry_loop ();
        }

    } else if (!_curr_master) {

        _curr_master = m;
        rc = 1;

        // initialize our hash ring.  The _poke_after_refresh
        // event will be fired when the first refresh is completed...
        twait { 
            _poke_after_refresh = mkevent ();
            refresh_loop (true);
        }

    } else {
        rc = 0;
    }

    ev->trigger (rc);
}

//-----------------------------------------------------------------------

tamed void
dsdc_smartcli_t::proxy_connect (dsdci_proxy_t *m, evi_t ev)
{
    tvars {
        bool ok (false);
        int rc (-1);
    }

    twait { m->connect (mkevent (ok)); }
    
    if (!ok) {
        if (show_debug(DSDC_DBG_MED)) {
            warn << "connection to proxy: " << m->key() << " failed\n";
        }

        rc = -1;
        m->retry_loop ();

    } else {
        rc = 0;
    }

    ev->trigger (rc);
}

//-----------------------------------------------------------------------------

ptr<dsdci_proxy_t> 
dsdc_smartcli_t::get_proxy() {
    if (!_proxies.size()) return NULL;

    ptr<dsdci_proxy_t> conn(NULL);
    size_t index = rand() % _proxies.size();
    size_t tries = 0;
    while (_proxies[index]->is_dead() && tries < _proxies.size()) {
        index = (index + 1) % _proxies.size();
        tries++;
    }
    if (tries < _proxies.size())
        conn = _proxies[index];

    return conn;
}

//-----------------------------------------------------------------------

tamed void
dsdc_smartcli_t::init (evb_t::ptr ev)
{
    tvars {
        dsdci_master_t *m;
        rendezvous_t<ptr<int> > rv;
        ptr<int> i;
        size_t count (0);
        bool success (false);
        int pi;
        size_t j;
    }

    twait {
        for (j = 0; j < _proxies.size(); j++)
            proxy_connect(_proxies[j], mkevent(pi));
    }

    for (m = _masters.first; m; m = _masters.next (m)) {
        i = New refcounted<int> (-1);
        master_connect (m, mkevent (rv, i, *i));
        count++;
    }

    while (count > 0) {
        twait (rv, i);
        count --;

        // We're waiting for the first guy to report that he's successfully
        // started up. When we get him, we're OK to report to the caller
        // success (and clear out the event so that it's only called once).
        if (*i == 1) {
            success = true;
            if (ev) {
                evb_t::ptr tmp = ev;
                ev = NULL;
                tmp->trigger (true); 
            }
        }
    }

    // if all connects failed, then still start the refresh timer anyways,
    // even though it will definitely fail at first.
    if (!success && (_opts & DSDC_RETRY_ON_STARTUP))
        refresh_loop (true);

    if (ev) ev->trigger (false);
}

//-----------------------------------------------------------------------
// deal with lock acquiring and releasing
//
static void
acquire_cb_2 (dsdc_lock_acquire_res_cb_t cb,
              ptr<dsdc_lock_acquire_res_t> res,
              clnt_stat err)
{
    if (err) {
        if (show_debug (DSDC_DBG_LOW)) {
            warn << "Acquire failed with RPC error: " << err << "\n";
        }
        res->set_status (DSDC_RPC_ERROR);
        *res->err = err;
    }
    (*cb) (res);
}

//-----------------------------------------------------------------------

void
dsdc_smartcli_t::acquire_cb_1 (ptr<dsdc_lock_acquire_arg_t> arg,
                               dsdc_lock_acquire_res_cb_t cb,
                               ptr<aclnt> cli)
{
    if (!cli) {
        (*cb) (New refcounted<dsdc_lock_acquire_res_t> (DSDC_DEAD));
    } else {
        ptr<dsdc_lock_acquire_res_t> res =
            New refcounted<dsdc_lock_acquire_res_t> ();
        rpc_call (cli, DSDC_LOCK_ACQUIRE, arg, res, 
                  wrap (acquire_cb_2, cb, res));
    }
}

//-----------------------------------------------------------------------

tamed void
dsdc_smartcli_t::lock_release (ptr<dsdc_lock_release_arg_t> arg,
                               cbi::ptr cb, bool safe)
{
    tvars {
        dsdc_res_t res (DSDC_OK);
        ptr<aclnt> cli;
        clnt_stat err;
    }

    if (!safe) {
        if (!_lock_server) {
            res = DSDC_NONODE;
        } else {
            twait { _lock_server->get_aclnt (mkevent (cli)); }
        }
    } else {
        cli = get_primary ();
    }

    if (!cli) {
        if (res == DSDC_OK)
            res = DSDC_DEAD;
    } else {
        // No timeouts for now.
        twait {
            RPC::dsdc_prog_1::dsdc_lock_release (cli, arg, &res, mkevent (err));
        }
        if (err) {
            if (show_debug (DSDC_DBG_LOW)) {
                warn << "Acquire failed with RPC error: " << err << "\n";
            }
            res = DSDC_RPC_ERROR;
        }
    }
    TRIGGER (cb, int (res));
}


void
dsdc_smartcli_t::lock_acquire (ptr<dsdc_lock_acquire_arg_t> arg,
                               dsdc_lock_acquire_res_cb_t cb, bool safe)
{
    if (safe) {
        acquire_cb_1 (arg, cb, get_primary ());
    } else if (!_lock_server) {
        (*cb) (New refcounted<dsdc_lock_acquire_res_t> (DSDC_NONODE));
    } else {
        _lock_server->get_aclnt (wrap (this, &dsdc_smartcli_t::acquire_cb_1,
                                       arg, cb));
    }
}
//
//
//-----------------------------------------------------------------------

//-----------------------------------------------------------------------
// reconnect to masters after connections failed; this code should
// be combined with the code for the slaves trying to reconnect in
// slave.C
//

tamed void
dsdci_retry_srv_t::retry_loop ()
{
    tvars {
        ptr<bool> df;
        bool first (true);
        bool ok (false);
        ptr<dsdci_retry_srv_t> hold;
    }
    hold = mkref (this);

    if (show_debug(DSDC_DBG_HI)) {
        warn << "starting retry loop: " << key() << "\n";
    }

    df = _destroyed;
    while (!*df && !ok && !_orphaned) {

        if (first) { first = false; }
        else { 
            
            if (show_debug (DSDC_DBG_MED))
                warn << "Retrying remote master: " << key () << "\n";

            twait { connect (mkevent (ok)); }
            if (ok) {
                if (show_debug (DSDC_DBG_LOW)) {
                    warn << "Retry succeeded: " << key () << "\n";
                }
            }
        }
        if (!ok) { 
            twait { delaycb (dsdc_retry_wait_time, 0, mkevent ()); }
        }
    }
}

//
//-----------------------------------------------------------------------

bool 
dsdc_smartcli_t::obj_too_big (const dsdc_obj_t &obj)
{
  // conservative limit with overhead from put packet
  size_t lim = dsdc_packet_sz - 
    sizeof (dsdc_put4_arg_t) - 
    sizeof (dsdc_cksum_t);

  return obj.size () >  lim;
}

//-----------------------------------------------------------------------
