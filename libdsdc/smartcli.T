
// -*-c++-*-
/* $Id$ */

#include "dsdc.h"
#include "dsdc_const.h"

dsdci_srv_t::dsdci_srv_t (const str &h, int p)
        : _key (strbuf ("%s:%d", h.cstr (), p)),
        _hostname (h),
        _port (p),
        _fd (-1),
        _destroyed (New refcounted<bool> (false))
{ }

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

void
dsdci_master_t::eof_hook ()
{
    schedule_retry ();
}

bool
dsdc_smartcli_t::add_master (const str &m)
{
    str hostname = "127.0.0.1";
    int port = dsdc_port;
    if (!parse_hn (m, &hostname, &port))
        return false;
    return add_master (hostname, port);
}

bool
dsdc_smartcli_t::add_master (const str &hostname, int port)
{
    dsdci_master_t *m = New dsdci_master_t (hostname, port);
    if (_masters_hash[m->key ()]) {
        warn << "duplicate master ignored: " << m->key () << "\n";
        delete m;
        return false;
    }

    _masters_hash.insert (m);
    _masters.insert_tail (m);
    return true;
}

dsdc_smartcli_t::~dsdc_smartcli_t ()
{
    _masters_hash.deleteall ();
    _slaves_hash.deleteall ();
}

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

void
dsdc_smartcli_t::pre_construct ()
{
    _slaves_hash_tmp.clear ();
}

aclnt_wrap_t *
dsdc_smartcli_t::new_lockserver_wrap (const str &h, int p)
{
    return New dsdci_slave_t (h, p);
}

aclnt_wrap_t *
dsdc_smartcli_t::new_wrap (const str &h, int p)
{
    dsdci_slave_t *s = New dsdci_slave_t (h, p);
    dsdci_slave_t *ret = NULL;
    if ((ret = _slaves_hash[s->key ()])) {
        // already there; no need to jostle the tree at all
        delete s;
    } else {
        _slaves_hash.insert (s);
        _slaves.insert_head (s);
        ret = s;
    }

    if (_slaves_hash_tmp[ret->key ()]) {
        warn << "doubly-allocated slave: " << ret->key () << "\n";
    } else {
        _slaves_hash_tmp.insert (ret->key ());
    }

    return ret;
}

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
            delete s;
        }
    }

    // Only on initialization do we need to do this.  We delay return to
    // the caller until after we've initialized the hash ring via
    // the standard state refresh mechanism.
    if (poke_after_refresh) {
        poke_after_refresh->success ();
        poke_after_refresh = NULL;
    }
}

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
    }

    if (safe) {
        cli = get_primary ();
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

void
dsdc_smartcli_t::put (ptr<dsdc_put3_arg_t> arg, cbi::ptr cb, bool safe)
{
    change_cache<dsdc_put3_arg_t> (arg->key, arg, int (DSDC_PUT3), cb, safe);
}

void
dsdc_smartcli_t::put (ptr<dsdc_put_arg_t> arg, cbi::ptr cb, bool safe)
{
    change_cache<dsdc_put_arg_t> (arg->key, arg, int (DSDC_PUT), cb, safe);
}

void
dsdc_smartcli_t::remove (ptr<dsdc_key_t> key, cbi::ptr cb, bool safe)
{
    change_cache<dsdc_key_t> (*key, key, int (DSDC_REMOVE), cb, safe);
}

void
dsdc_smartcli_t::remove (ptr<dsdc_remove3_arg_t> arg, cbi::ptr cb, bool safe)
{
    change_cache (arg->key, arg, int (DSDC_REMOVE3), cb, safe);
}

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

void
dsdci_srv_t::connect_cb (cbb cb, ptr<bool> df, int f)
{
    bool ret = true;
    if (*df) {
        ret = false;
    } else if ((_fd = f) < 0) {
        if (show_debug (DSDC_DBG_LOW)) {
            warn << "connection to " << typ () << " failed: " << key () << "\n";
        }
        ret = false;
    } else {
        if (show_debug (DSDC_DBG_MED)) {
            warn << "connection to " << typ () << " succeeded: " << key () << "\n";
        }
        assert ((_x = axprt_stream::alloc (_fd, dsdc_packet_sz)));
        _cli = aclnt::alloc (_x, dsdc_prog_1);
        _cli->seteofcb (wrap (this, &dsdci_srv_t::hit_eof, _destroyed));
    }
    (*cb) (ret);
}

void
dsdci_srv_t::connect (cbb cb)
{
    if (!is_dead ()) {
        (*cb) (true);
        return;
    }
    tcpconnect (_hostname, _port, wrap (this, &dsdci_srv_t::connect_cb,
                                        cb, _destroyed));
}

void
dsdci_srv_t::get_aclnt_cb (aclnt_cb_t cb, ptr<bool> df, bool b)
{
    if (*df)
        (*cb) (NULL);
    else
        (*cb) (_cli);
}

void
dsdci_srv_t::get_aclnt (aclnt_cb_t cb)
{
    if (!is_dead () && _cli) {
        (*cb) (_cli);
        return;
    }
    connect (wrap (this, &dsdci_srv_t::get_aclnt_cb, cb, _destroyed));
}

void
dsdc_smartcli_t::init_cb (ptr<init_t> i, dsdci_master_t *m, bool b)
{
    // in this case, it's the first success
    if (b && !_curr_master) {
        _curr_master = m;

        // initialize our hash ring
        poke_after_refresh = i;
        refresh (_destroyed);
    }
    if (!b && (_opts & DSDC_RETRY_ON_STARTUP)) {
        m->schedule_retry ();
    }
}

void
dsdc_smartcli_t::last_finished (cbb::ptr cb, bool b)
{
    // if all connects failed, then still start the refresh timer anyways,
    // even though it will definitely fail at first.
    if (!b && (_opts & DSDC_RETRY_ON_STARTUP))
        refresh (_destroyed);
    if (cb)
        (*cb) (b);
}


void
dsdc_smartcli_t::init (cbb::ptr cb)
{
    ptr<init_t> i =
        New refcounted<init_t> (wrap (this, &dsdc_smartcli_t::last_finished, cb));
    for (dsdci_master_t *m = _masters.first; m; m = _masters.next (m)) {
        m->connect (wrap (this, &dsdc_smartcli_t::init_cb, i, m));
    }
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
        rpc_call (cli, DSDC_LOCK_ACQUIRE, arg, res, wrap (acquire_cb_2, cb, res));
    }
}

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
void
dsdci_master_t::schedule_retry ()
{
    delaycb (dsdc_retry_wait_time, 0,
             wrap (this, &dsdci_master_t::retry, _destroyed));
}

void
dsdci_master_t::retry_cb (ptr<bool> df, bool res)
{
    if (*df)
        return;
    if (res) {
        if (show_debug (DSDC_DBG_LOW))
            warn << "Retry succeeded: " << key () << "\n";
    } else {
        schedule_retry ();
    }
}

void
dsdci_master_t::retry (ptr<bool> df)
{
    if (*df)
        return;

    if (show_debug (DSDC_DBG_MED))
        warn << "Retrying remote peer: " << key () << "\n";

    connect (wrap (this, &dsdci_master_t::retry_cb, df));
}
//
//-----------------------------------------------------------------------
