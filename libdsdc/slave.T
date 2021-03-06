// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-
//-----------------------------------------------------------------------
/*
 * $Id$
 */

#include "xdrmisc.h"
#include "dsdc.h"
#include "dsdc_slave.h"
#include "dsdc_const.h"
#include "dsdc_prot.h"
#include "dsdc_util.h"
#include "dsdc_stats.h"
#include "dsdc_stats1.h"
#include "dsdc_stats2.h"
#include "crypt.h"

void
dsdc_cache_obj_t::set (const dsdc_key_t &k, const dsdc_obj_t &o,
                       dsdc::annotation::base_t *a)
{
    _key = k;
    _obj = o;

    if ((_annotation = a)) {
        a->elem_create (_obj.size ());
    }
}

bool
dsdc_cache_obj_t::match_checksum (const dsdc_cksum_t &cksum) const
{
    dsdc_cksum_t tmp;
    return (sha1_hashxdr (tmp.base (), _obj) &&
            memcmp (tmp.base (), cksum.base (), cksum.size()) == 0);
}

void
dsdcs_master_t::connect_cb (int f)
{
    if (f < 0) {
        went_down (strbuf ("could not connect to host: %m"), DSDC_DBG_LOW);
        return;
    }
    if (show_debug (DSDC_DBG_LOW))
        master_warn ("connection succeeded");

    _fd = f;
    assert ((_x = axprt_stream::alloc (_fd, dsdc_packet_sz)));
    _cli = aclnt::alloc (_x, dsdc_prog_1);
    _srv = asrv::alloc (_x, dsdc_prog_1,
                        wrap (this, &dsdcs_master_t::dispatch));
    _status = MASTER_STATUS_UP;

    do_register ();
}

void
dsdcs_master_t::ready_to_serve ()
{
    _status = MASTER_STATUS_OK;
    schedule_heartbeat ();
}

tamed void
dsdcs_master_t::heartbeat_T ()
{
    tvars {
        dsdc_res_t res;
        bool succ (false);
        clnt_stat err;
    }
    if (_status == MASTER_STATUS_OK && _cli) {
        twait {
            RPC::dsdc_prog_1::dsdc_heartbeat (_cli, &res, mkevent (err));
            schedule_heartbeat ();
        }
        if (err) {
            warn << "RPC error in DSDC_HEARTBEAT: " << err << "\n";
        } else if (res != DSDC_OK) {
            warn << "DSDC error in DSDC_HEARTBEAT: " << int (res) << "\n";
        } else {
            succ = true;
        }
        if (!succ)
            went_down ("Heartbeat ACK failed");
    }
}

void
dsdcs_master_t::schedule_heartbeat ()
{
    delaycb (dsdc_heartbeat_interval, 0,
             wrap (this, &dsdcs_master_t::heartbeat));
}

ptr<aclnt>
dsdc_slave_app_t::get_primary ()
{
    for (dsdcs_master_t *m = _masters.first; m ; m = _masters.next (m)) {
        if (m->status () == MASTER_STATUS_OK)
            return m->cli ();
    }
    return NULL;
}

//-----------------------------------------------------------------------

tamed void
dsdc_slave_t::clean_cache_T ()
{
    tvars {
        dsdc_cache_obj_t *p;
        size_t tot (0);
        int nobj (0);
        dsdc_ring_node_t *nn;
        size_t batch_iters (0);
        time_t delay_ns (0);
    }

    if (_opts & SLAVE_NO_CLEAN) { /* noop */ }
    else if (_cleaning) { _dirty = true; }
    else {

        _cleaning = true;
        if (dsdcs_clean_batch && dsdcs_clean_wait_us) {
            delay_ns = dsdcs_clean_wait_us * 1000;
        }
        
        do {
            _dirty = false;

            _lru.slow_reset ();
            batch_iters = 0;

            while (!_dirty && (p = _lru.slow_next ())) {
                
                nn = _hash_ring.successor (p->_key);
                if (!nn || !_khash[nn->_key]) {
                    
                    if (show_debug (DSDC_DBG_MED)) {
                        warn ("CLEAN: removed object: %s\n",
                              key_to_str (p->_key).cstr () );
                    }
                    
                    tot += lru_remove_obj (p, true, dsdc::AC_CLEAN);
                    nobj ++;
                }

                if (delay_ns && (batch_iters == dsdcs_clean_batch)) {
                    twait { delaycb (0, delay_ns, mkevent ()); }
                    if (show_debug (DSDC_DBG_MED)) {
                        warn ("CLEAN: wait %dus (after %zu iterations)\n",
                              int (dsdcs_clean_wait_us), batch_iters);
                    }
                    batch_iters = 0;
                } else {
                    batch_iters++;
                }
            }

            if (_dirty && show_debug (DSDC_DBG_MED)) {
                warn ("CLEAN: retrying the cleaner after getting dirtied\n");
            }
            
        } while (_dirty);
        
        _n_updates_since_clean = 0;

        if (show_debug (DSDC_DBG_LOW)) {
            warn ("CLEAN: cleaned %d objects (%zu bytes in total)\n", 
                  nobj, tot);
        }

        _cleaning = false;
    }

}

//-----------------------------------------------------------------------

tamed void
dsdcs_master_t::do_register ()
{
    tvars {
        dsdc_res_t res;
        dsdc_register_arg_t arg;
        clnt_stat err;

    }
    _slave->get_xdr_repr (&arg.slave);
    arg.primary = _primary;
    arg.lock_server = _slave->is_lock_server ();

    twait {
        RPC::dsdc_prog_1::dsdc_register (_cli, arg, &res, mkevent (err));
    }
    if (err) {
        strbuf b;
        b << "Register failed: " << err ;
        went_down (b);
    } else if (res != DSDC_OK) {
        went_down (strbuf ("register returned error message %d", int(res)));
    } else {
        ready_to_serve ();
    }
}


void
dsdcs_master_t::connect ()
{
    _status = MASTER_STATUS_CONNECTING;
    tcpconnect (_hostname, _port, wrap (this, &dsdcs_master_t::connect_cb));
}

void
dsdcs_master_t::dispatch (svccb *sbp)
{
    if (!sbp) {
        went_down ("EOF on connection");
        return;
    }
    _slave->dispatch (sbp);
}

void
dsdcs_p2p_cli_t::dispatch (svccb *sbp)
{
    if (!sbp) {
        if (show_debug (DSDC_DBG_MED))
            warn << "EOF from " << _hn << "\n";
        delete (this);
    } else if (_x->getfd () < 0) {
        warn << "Swallowing RPC from destroyed client: " << _hn << "\n";
    } else {
        _parent->dispatch (sbp);
    }
}

void
dsdcs_lockserver_t::dispatch (svccb *sbp)
{
    switch (sbp->proc ()) {
    case DSDC_LOCK_ACQUIRE:
        acquire (sbp);
        break;
    case DSDC_LOCK_RELEASE:
        release (sbp);
        break;
    default:
        sbp->reject (PROC_UNAVAIL);
        break;
    }
}

void
dsdc_slave_t::handle_get_stats (svccb *sbp)
{
    dsdc_get_stats_single_arg_t *a =
        sbp->Xtmpl getarg<dsdc_get_stats_single_arg_t> ();
    dsdc_get_stats_single_res_t res;
    dsdc::stats::collector_base_t *cl = dsdc::stats::collector ();

    cl->prepare_sweep ();

    for (dsdc_cache_obj_t *o = _lru.first (); o; o = _lru.next (o)) {
        o->collect_statistics (false);
    }
    res.set_status (DSDC_OK);
    dsdc_res_t rc = cl->output (res.stats, a->params);

    if (rc != DSDC_OK)
        res.set_status (rc);

    sbp->replyref (res);
}

void
dsdc_slave_t::handle_set_stats_mode (svccb *sbp)
{
    bool *b = sbp->Xtmpl getarg<bool> ();
    bool prev = _stats_mode;

    warn << "Stats mode update: " << prev << " -> " << _stats_mode << "\n";
    set_stats_mode (*b);

    sbp->replyref (NULL);
}

void
dsdc_slave_t::dispatch (svccb *sbp)
{
    switch (sbp->proc ()) {
    case DSDC_GET:
    case DSDC_GET2:
    case DSDC_GET3:
        handle_get (sbp);
        break;
    case DSDC_MGET:
        handle_mget (sbp);
        break;
    case DSDC_PUT:
        handle_put (sbp);
        break;
    case DSDC_PUT3:
        handle_put3 (sbp);
        break;
    case DSDC_PUT4:
        handle_put4 (sbp);
        break;
    case DSDC_REMOVE:
    case DSDC_REMOVE3:
        handle_remove (sbp);
        break;
    case DSDC_MGET2:
        handle_mget (sbp);
        break;
    case DSDC_SET_STATS_MODE:
        handle_set_stats_mode (sbp);
        break;
    case DSDC_GET_STATS_SINGLE:
        handle_get_stats (sbp);
        break;

    default:
        sbp->reject (PROC_UNAVAIL);
        break;
    }
}

// XXX copy + paste from master.C
void
dsdc_slave_app_t::new_connection ()
{
    sockaddr_in sin;
    bzero (&sin, sizeof (sin));
    socklen_t sinlen = sizeof (sin);
    int nfd = accept (_lfd, reinterpret_cast<sockaddr *> (&sin), &sinlen);
    if (nfd >= 0) {
        strbuf hn ("%s:%d", inet_ntoa (sin.sin_addr), sin.sin_port);
        if (show_debug (DSDC_DBG_MED))
            warn << "accepting connection from " << hn << "\n";
        vNew dsdcs_p2p_cli_t (this, nfd, hn);
    } else if (errno != EAGAIN)
        warn ("accept failed: %m\n");
}


void
dsdcs_master_t::master_warn (const str &m)
{
    warn ("%s:%d: %s\n", _hostname.cstr (), _port, m.cstr ());
}

void
dsdcs_master_t::went_down (const str &why, u_int lev)
{
    _x = NULL;
    _cli = NULL;
    _srv = NULL;

    if (lev == 0 || show_debug (lev))
        master_warn (why);

    _status = MASTER_STATUS_DOWN;
    schedule_retry ();
}

void
dsdcs_master_t::retry ()
{
    connect ();
}

void
dsdcs_master_t::schedule_retry ()
{
    delaycb (dsdc_retry_wait_time, 0,
             wrap (this, &dsdcs_master_t::retry));
}

void
dsdc_slave_t::handle_mget (svccb *sbp)
{
    dsdc_mget2_arg_t *arg2 = NULL;
    dsdc_mget_arg_t *arg = NULL;
    dsdc_mget_res_t res;
    u_int sz=0;

    if (sbp->proc() == DSDC_GET2) {
        arg2 = sbp->Xtmpl getarg<dsdc_mget2_arg_t> ();
        sz = arg2->size ();
    } else {
        arg = sbp->Xtmpl getarg<dsdc_mget_arg_t> ();
        sz = arg->size ();
    }
    res.setsize (sz);

    for (u_int i = 0; i < sz; i++) {
        dsdc_obj_t *o;
        if (sbp->proc() == DSDC_GET2) {
            dsdc_req_t k = (*arg2)[i];
            o = lru_lookup ( k.key , k.time_to_expire );
            res[i].key = k.key;
        } else {
            dsdc_key_t k = (*arg)[i];
            o = lru_lookup ( k );
            res[i].key = k;
        }

        if (o) {
            res[i].res.set_status (DSDC_OK);
            *(res[i].res.obj) = *o;
        } else {
            res[i].res.set_status (DSDC_NOTFOUND);
        }
    }
    sbp->replyref (res);

}

void
dsdc_slave_t::handle_get (svccb *sbp)
{
    dsdc_obj_t *o;
    bool expired = false;

    switch (sbp->proc ()) {
    case DSDC_GET2:
    {
        dsdc_req_t *k = sbp->Xtmpl getarg<dsdc_req_t> ();
        o = lru_lookup (k->key, k->time_to_expire);
        break;
    }
    case DSDC_GET3:
    {
        dsdc_get3_arg_t *a = sbp->Xtmpl getarg<dsdc_get3_arg_t> ();
        dsdc::annotation::base_t *an;
        an = dsdc::stats::collector ()->alloc (a->annotation);
        o = lru_lookup (a->key, a->time_to_expire, an, &expired);
        break;
    }
    case DSDC_GET:
    {
        dsdc_key_t *k = sbp->Xtmpl getarg<dsdc_key_t> ();
        o = lru_lookup (*k);
        break;
    }
    default:
        panic ("Unexpected DSDC_GET type.\n");
    }

    dsdc_get_res_t res;
    if (o) {
        res.set_status (DSDC_OK);
        *res.obj = *o;
    } else {
        if (expired)
            res.set_status (DSDC_EXPIRED);
        else
            res.set_status (DSDC_NOTFOUND);
    }

    sbp->replyref (res);
}

void
dsdc_slave_t::handle_remove (svccb *sbp)
{
    dsdc_key_t *k = NULL;
    dsdc_remove3_arg_t *a3 = NULL;
    dsdc_res_t res;

    switch (sbp->proc ()) {
    case DSDC_REMOVE:
        k = sbp->Xtmpl getarg<dsdc_key_t> ();
        break;
    case DSDC_REMOVE3:
        a3 = sbp->Xtmpl getarg<dsdc_remove3_arg_t> ();
        k = &a3->key;
        break;
    default:
        panic ("Unexpected case in REMOVE handling.\n");
        break;
    }

    if (lru_remove (*k)) {
        res = DSDC_OK;
    } else {
        res = DSDC_NOTFOUND;
        if (a3) {
            dsdc::stats::collector ()->missed_remove (a3->annotation);
        }
    }

    if (show_debug (DSDC_DBG_MED)) {
        warn ("remove issued (rc=%d): %s\n", res, key_to_str (*k).cstr ());
    }
    sbp->replyref (res);
}

void
dsdc_slave_t::handle_put (svccb *sbp)
{
    RPC::dsdc_prog_1::dsdc_put_srv_t<svccb> srv (sbp);
    const dsdc_put_arg_t *a = srv.getarg ();
    dsdc_res_t res = handle_put (a->key, a->obj);
    srv.reply (res);
}

void
dsdc_slave_t::handle_put3 (svccb *sbp)
{
    RPC::dsdc_prog_1::dsdc_put3_srv_t<svccb> srv (sbp);
    const dsdc_put3_arg_t *a = srv.getarg ();
    dsdc::annotation::base_t *n = NULL;
    n = dsdc::stats::collector ()->alloc (a->annotation);
    dsdc_res_t res = handle_put (a->key, a->obj, n);
    srv.reply (res);
}

void
dsdc_slave_t::handle_put4 (svccb *sbp)
{
    RPC::dsdc_prog_1::dsdc_put4_srv_t<svccb> srv (sbp);
    const dsdc_put4_arg_t *a = srv.getarg ();
    dsdc::annotation::base_t *n = NULL;
    n = dsdc::stats::collector ()->alloc (a->annotation);
    dsdc_res_t res = handle_put (a->key, a->obj, n, a->checksum);
    srv.reply (res);
}

dsdc_res_t
dsdc_slave_t::handle_put (const dsdc_key_t &k, const dsdc_obj_t &o,
                          dsdc::annotation::base_t *a,
                          const dsdc_cksum_t *cksum)
{
    dsdc_res_t res = lru_insert (k, o, a, cksum);
    if (show_debug (DSDC_DBG_MED)) {
        warn ("insert issued (rc=%d): %s\n", res, key_to_str (k).cstr ());
    }
    return res;
}

dsdc_obj_t *
dsdc_slave_t::lru_lookup (const dsdc_key_t &k, const int expire,
                          dsdc::annotation::base_t *a, bool* expired)
{
    dsdc_cache_obj_t *o = _objs[k];
    dsdc_obj_t *ret = NULL;

    dsdc::action_code_t code = dsdc::AC_NONE;

    if (o) {
        if  (expire > 0 && (sfs_get_timenow () - expire >= o->_timein)) {
            code = dsdc::AC_EXPIRED;
            lru_remove_obj(o, true, dsdc::AC_EXPIRED);
            o = NULL;
            if (expired) *expired = true;
        } else {
            code = dsdc::AC_HIT;
            o->inc_gets ();
            _lru.remove (o);
            _lru.insert_tail (o);
            ret = &o->_obj;
        }
    } else {
        code = dsdc::AC_NOT_FOUND;
    }

    if (a || (o && (a = o->annotation ()) && code == dsdc::AC_HIT)) {
        a->mark_get_attempt (code);
    }
    return ret;
}

void
dsdc_cache_obj_t::collect_statistics (bool del, dsdc::action_code_t t)
{
    if (_annotation) {
        _annotation->collect (_n_gets, _n_gets_in_epoch, lifetime (),
                              _obj.size (), del, t);
        _n_gets_in_epoch = 0;
    }
}

size_t
dsdc_slave_t::lru_remove_obj (dsdc_cache_obj_t *o, bool del,
                              dsdc::action_code_t t)
{
    if (!o) {
        o = _lru.first ();

        // it could be that what's inserted is bigger than the whole cache
        // size allotment.  in this case, we'll bend the rules a little
        // bit and allow only it to be inserted.
        if (!o)
            return 0;

        if (show_debug (DSDC_DBG_MED))
            warn ("LRU Delete triggered: %s\n", key_to_str (o->_key).cstr ());
    }

    assert (o);

    _lru.remove (o);
    _objs.remove (o);
    o->collect_statistics (true, t);

    size_t sz = o->size ();
    assert (_lrusz >= sz);
    _lrusz -= sz;

    if (del)
        delete o;

    return sz;
}

bool
dsdc_slave_t::lru_remove (const dsdc_key_t &k)
{
    dsdc_cache_obj_t *o = _objs[k];
    bool ret = false;
    if (o) {
        lru_remove_obj (o, true, dsdc::AC_EXPLICIT);
        ret = true;
    }
    return ret;
}

//-----------------------------------------------------------------------

dsdc_res_t
dsdc_slave_t::lru_insert (const dsdc_key_t &k, const dsdc_obj_t &o,
                          dsdc::annotation::base_t *a,
                          const dsdc_cksum_t *cksum)
{
    dsdc_res_t ret = DSDC_INSERTED;
    dsdc_cache_obj_t *co;

    if ((co = _objs[k])) {

        if (cksum && !co->match_checksum (*cksum)) {
            ret = DSDC_DATA_CHANGED;
        } else {

            lru_remove_obj (co, false, dsdc::AC_REPLACE);

            // this reset needs to come after the above lru_remove_obj
            // to preserve statistics.
            co->reset ();
            
            ret = DSDC_REPLACED;
        }
    } else if (cksum && !is_empty_checksum (*cksum)) {
        ret = DSDC_DATA_DISAPPEARED;
    } else {
        co = New dsdc_cache_obj_t ();
        ret = DSDC_INSERTED;
    }

    // Only in the success cases should we continue with the insert!
    if (ret == DSDC_INSERTED || ret == DSDC_REPLACED) {
        co->set (k, o, a);

        size_t sz = co->size ();

        // stop looping when either (1) we've made enough room or
        // (2) there is nothing more to delete!
        while (_lrusz && sz + _lrusz > _maxsz) {
            lru_remove_obj (NULL, true, dsdc::AC_MAKE_ROOM);
        }
        
        _lru.insert_tail (co);
        _objs.insert (co);
        _lrusz += co->size ();
    }

    return ret;
}

void
dsdc_slave_app_t::add_master (const str &h, int p)
{
    dsdcs_master_t *m = New dsdcs_master_t (this, h, p, _primary);
    if (_primary)
        _primary = false;

    _masters.insert_head (m);
}

void
dsdc_slave_t::genkeys ()
{
    dsdc_key_template_t t;
    t.port = _port;

    if (_opts & SLAVE_DETERMINISTIC_SEEDS)
        t.pid = 0;
    else
        t.pid = getpid ();

    if (!(t.hostname = dsdc_hostname))
        t.hostname = myname ();

    _keys.setsize (_n_nodes);

    for (u_int i = 0; i < _n_nodes; i++) {
        t.id = i;
        sha1_hashxdr (_keys[i].base (), t);
        _khash.insert (_keys[i]);
    }
}

bool
dsdc_slave_app_t::init ()
{
    if (!get_port ())
        return false;
    for (dsdcs_master_t *m = _masters.first; m ; m = _masters.next (m)) {
        m->connect ();
    }
    return true;
}

bool
dsdc_slave_t::init ()
{
    if (!dsdc_slave_app_t::init ())
        return false;

    genkeys ();

    // Wait a few seconds before refreshing the ring, so that way
    // the connections have a chance to fire up.  Please excuse
    // this hack, it's kind of gross.
    refresh_loop (false);
    return true;
}

bool
dsdc_slave_app_t::get_port ()
{
    _lfd = -1;
    int p_begin = _port;
    u_int i;
    for (i = 0; i < dsdcs_port_attempts && i < USHRT_MAX && _lfd < 0; i++) {
        _lfd = inetsocket (SOCK_STREAM, _port);
        if (_lfd < 0) {
            if (show_debug (DSDC_DBG_LOW))
                warn ("port=%d attempt failed: %m\n", _port);
            _port++;
        }
    }
    if (_lfd > 0) {
        if (show_debug (DSDC_DBG_LOW))
            warn ("found port = %d\n", _port);
        close_on_exec (_lfd);
        if (listen (_lfd, 256) < 0) {
            warn << "listen() failed, possible race to port, trying new one\n";
            close(_lfd);
            return get_port();
        }
        fdcb (_lfd, selread, wrap (this, &dsdc_slave_t::new_connection));
        return true;
    } else {
        warn << "tried ports from " << p_begin << " to " << p_begin + i
        << "; all failed\n";
        return false;
    }
}

str
dsdc_slave_app_t::startup_msg () const
{
    strbuf b ("listening on %s:%d", dsdc_hostname.cstr (), _port);
    startup_msg_v (&b);
    return b;
}

void
dsdc_slave_t::startup_msg_v (strbuf *b) const
{
    if (show_debug (DSDC_DBG_LOW)) {
        b->fmt ("; nnodes=%d, maxsz=0x%zx, clean_batch=%d, clean_wait=%dus", 
                _n_nodes, _maxsz, int (dsdcs_clean_batch), 
                int (dsdcs_clean_wait_us));
    }
}

//-----------------------------------------------------------------------

dsdc_slave_t::dsdc_slave_t (u_int n, size_t s, int p, int o)
    : dsdc_slave_app_t (p, o),
      dsdc_system_state_cache_t (),
      _lrusz (0),
      _n_nodes (n ? n : dsdc_slave_nnodes),
      _maxsz (s ? s : dsdc_slave_maxsz),
      _cleaning (false),
      _dirty (false) {}

//-----------------------------------------------------------------------

dsdc_slave_app_t::dsdc_slave_app_t (int p, int o)
    : dsdc_app_t (),
      _primary (false),
      _port (p < 0 ? dsdc_slave_port : p),
      _lfd (-1),
      _opts (o),
      _stats_mode (false),
      _stats_mode2 (-1) {}

void
dsdc_slave_app_t::get_xdr_repr (dsdcx_slave_t *x)
{
    x->port = _port;
    x->hostname = dsdc_hostname;
}

void
dsdc_slave_t::get_xdr_repr (dsdcx_slave_t *x)
{
    dsdc_slave_app_t::get_xdr_repr (x);
    x->keys = _keys;
}

void
dsdcs_lockserver_t::get_xdr_repr (dsdcx_slave_t *x)
{
    dsdc_slave_app_t::get_xdr_repr (x);
    x->keys.setsize (0);
}

void
dsdc_slave_app_t::set_stats_mode (bool b)
{
    if (b && !_stats_mode) {
        dsdc::stats::set_collector (New dsdc::stats::collector1_t ());
    }
    _stats_mode = b;
}

//-----------------------------------------------------------------------

void
dsdc_slave_t::set_stats_mode2 (int i)
{
    if (i >= 0 && _stats_mode2 < 0) {
        dsdc::stats::set_collector (New dsdc::stats::collector2_t ());
        _stats_mode2 = i;
        run_stats2_loop ();
    } else if (i <= 0 && _stats_mode2 > 0) {
        dsdc::stats::set_collector (New dsdc::stats::collector_null_t ());
    }
}

//-----------------------------------------------------------------------

tamed void
dsdc_slave_t::run_stats2_loop ()
{
    tvars {
        bool go (true);
        dsdc::stats::collector_base_t *c;
    }

    while (go) {

        c = dsdc::stats::collector ();
        if (c->is_collector2 () && _stats_mode2 > 0) {

            c->start_interval ();

            twait { delaycb (_stats_mode2, 0, mkevent ()); }

            {
                for (dsdc_cache_obj_t *o = _lru.first ();
                     o;
                     o = _lru.next (o)) {
                    o->collect_statistics (false);
                }

                warnobj wo ((int) ::warnobj::xflag);
                c->output_to_log (wo);
            }


        } else {
            go  = false;
        }
    }
}

//-----------------------------------------------------------------------

void dsdc_lru_t::slow_reset () { _slow_cursor = first (); }

//-----------------------------------------------------------------------

dsdc_cache_obj_t *
dsdc_lru_t::slow_next ()
{
    dsdc_cache_obj_t *ret = _slow_cursor;
    if (_slow_cursor) { _slow_cursor = next (_slow_cursor); }
    return ret;
}

//-----------------------------------------------------------------------

void
dsdc_lru_t::remove (dsdc_cache_obj_t *o)
{
    if (o == _slow_cursor) { _slow_cursor = next (o); }
    _lru.remove (o);
}

//-----------------------------------------------------------------------

dsdc_cache_obj_t *dsdc_lru_t::first () { return _lru.first; }

//-----------------------------------------------------------------------

dsdc_cache_obj_t * dsdc_lru_t::next (dsdc_cache_obj_t *o)
{ return _lru.next (o); }

//-----------------------------------------------------------------------

void dsdc_lru_t::insert_tail (dsdc_cache_obj_t *o)
{ _lru.insert_tail (o); }

//-----------------------------------------------------------------------

