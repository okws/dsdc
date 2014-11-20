// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "dsdc_master.h"
#include "crypt.h"
#include "tame.h"
#include "dsdc_signal.h"
#include "rpc_stats.h"
#include "okconst.h"

extern "C" bool_t 
pmap_set(const u_long program, const u_long version, int protocol, 
         u_short port);

//-----------------------------------------------------------------------

bool
dsdc_master_t::init ()
{
    _lfd = inetsocket (SOCK_STREAM, _port);
    if (_lfd < 0) {
        warn ("in master init: %m\n");
        return false;
    }
    close_on_exec (_lfd);
    listen (_lfd, 256);
    fdcb (_lfd, selread, wrap (this, &dsdc_master_t::new_connection));

    pmap_set(DSDC_PROG, DSDC_VERS, IPPROTO_TCP, _port);

    // check periodically that nothing died on us with a bad heart.
    watchdog_timer_loop ();

    // log RPC stats
    get_rpc_stats()
        .set_active(true)
        .set_interval(ok_amt_rpc_stats_interval);

    return true;
}

//-----------------------------------------------------------------------

void
dsdc_master_t::new_connection ()
{
    sockaddr_in sin;
    bzero (&sin, sizeof (sin));
    socklen_t sinlen = sizeof (sin);
    int nfd = accept (_lfd, reinterpret_cast<sockaddr *> (&sin), &sinlen);
    if (nfd >= 0) {
        strbuf hn ("%s:%d", inet_ntoa (sin.sin_addr), sin.sin_port);
        warn << "accepting connection from " << hn << "\n";

        // Note that we have this client, and just let it do its own
        // thing. alloc() will call refcount_inc(), meaning this thing
        // will stay around **at least** until dsdcm_client_t::release()
        // is called on an EOF.
        dsdcm_client_t::alloc (this, nfd, hn);

    } else if (errno != EAGAIN)
        warn ("accept failed: %m\n");
}

//-----------------------------------------------------------------------

dsdcm_client_t::dsdcm_client_t (dsdc_master_t *ma, int f, const str &h)
    : _slave (NULL), _master (ma), _fd (f), _hostname (h)
{
    tcp_nodelay (_fd);
    _x = axprt_stream::alloc (_fd, dsdc_packet_sz);
    _asrv = asrv::alloc (_x, dsdc_prog_1,
                         wrap (this, &dsdcm_client_t::dispatch));
}

//-----------------------------------------------------------------------

void 
dsdcm_client_t::init () 
{ 
    refcount_inc ();
    _master->insert_client (this);
}

//-----------------------------------------------------------------------

ptr<dsdcm_client_t>
dsdcm_client_t::alloc (dsdc_master_t *ma, int f, const str &h)
{
    ptr<dsdcm_client_t> c = New refcounted<dsdcm_client_t> (ma, f, h);
    c->init ();
    return c;
}

//-----------------------------------------------------------------------

dsdcm_slave_base_t::dsdcm_slave_base_t (ptr<dsdcm_client_t> c, ptr<axprt> x)
    : _client (c)
{
    ptr<aclnt> acli = aclnt::alloc(x, dsdc_prog_1);
    _clnt_to_slave = New refcounted<aclnt_connection_t>(acli);

    // start them up with a heartbeat so not deleted right away!
    handle_heartbeat ();
}

//-----------------------------------------------------------------------

void
dsdcm_slave_base_t::release ()
{
    remove_nodes ();
    if (_client) { _client->unregister_slave(); }
}

//-----------------------------------------------------------------------

dsdcm_slave_t::dsdcm_slave_t (ptr<dsdcm_client_t> c, ptr<axprt> x,
                              str slave_type_str)
    : dsdcm_slave_base_t (c, x) 
{
    if (show_debug (DSDC_DBG_HI)) {
        warn ("New dsdcm_slave_t (%s) @ %p\n", slave_type_str.cstr(), this);
    }
    _client->get_master ()->insert_slave (this);
}

//-----------------------------------------------------------------------

ptr<dsdcm_slave_t>
dsdcm_slave_t::alloc (ptr<dsdcm_client_t> c, ptr<axprt> x)
{
    ptr<dsdcm_slave_t> s = New refcounted<dsdcm_slave_t> (c, x);
    return s;
}

//-----------------------------------------------------------------------------

ptr<dsdcm_redis_slave_t>
dsdcm_redis_slave_t::alloc(ptr<dsdcm_client_t> c, ptr<axprt> x) {
    ptr<dsdcm_redis_slave_t> s = New refcounted<dsdcm_redis_slave_t>(c,x);
    return s;
}

//-----------------------------------------------------------------------------

ptr<connection_t>
dsdcm_redis_slave_t::get_connection() {
    return m_redis; 
}

//-----------------------------------------------------------------------------

tamed void
dsdcm_redis_slave_t::get_connection(conn_cb_t cb) {
    
    tvars {
        str fullname, host;
        int port;
        vec<str> toks;
        bool ok;
    }

    fullname = _client->remote_peer_id();
    split(&toks, "\\:", fullname);

    host = toks[0];
    port = atoi(toks[1].cstr());

    m_redis = New refcounted<redis_connection_t>();
    twait {
        m_redis->connect(host, port, mkevent(ok));
    }

    if (!ok) {
        m_force_dead = true;
    }

    cb(m_redis);
}

//-----------------------------------------------------------------------------

bool
dsdcm_redis_slave_t::is_dead() {
    return m_force_dead || dsdcm_slave_t::is_dead();
}

//-----------------------------------------------------------------------

dsdcm_lock_server_t::dsdcm_lock_server_t (ptr<dsdcm_client_t> c, ptr<axprt> x)
    : dsdcm_slave_base_t (c, x)
{
    _client->get_master ()->insert_lock_server (this);
}

//-----------------------------------------------------------------------

dsdcm_lock_server_t::~dsdcm_lock_server_t ()
{
    _client->get_master ()->remove_lock_server (this);
}

//-----------------------------------------------------------------------

ptr<dsdcm_lock_server_t>
dsdcm_lock_server_t::alloc (ptr<dsdcm_client_t> c, ptr<axprt> x)
{
    ptr<dsdcm_lock_server_t> s = New refcounted<dsdcm_lock_server_t> (c, x);
    return s;
}

//-----------------------------------------------------------------------

dsdcm_slave_t::~dsdcm_slave_t ()
{
    if (show_debug (DSDC_DBG_HI)) {
        warn ("dsdcm_slave_t::~dsdcm_slave_t(%p)\n", this);
    }
    
    _client->get_master ()->remove_slave (this);
}

//-----------------------------------------------------------------------

void 
dsdc_master_t::insert_slave (dsdcm_slave_t *sl)
{ 
    _n_slaves ++; 
    _slaves.insert_head (sl); 
    _slave_hash.insert (sl); 
}

//-----------------------------------------------------------------------

void
dsdc_master_t::remove_slave (dsdcm_slave_t *sl)
{ 
    _n_slaves --; 
    _slaves.remove (sl);
    _slave_hash.remove (sl);
}

//-----------------------------------------------------------------------

void 
dsdc_master_t::remove_lock_server (dsdcm_lock_server_t *ls)
{ 
    _lock_servers.remove (ls); 
}

//-----------------------------------------------------------------------

void
dsdcm_client_t::dispatch (svccb *sbp)
{
    if (!sbp) {

        warn << "client " << remote_peer_id () << " gave EOF\n";

        // at the end of a TCP connection, we get a NULL sbp from SFS.
        // at this point, we need to clean up state for this particular
        // client. note that the destructor chain will trigger cleanup
        // of the hash ring in the case of slave nodes, which is very
        // important for generating correct results
        release ();

        // clear out the state fields since they are no longer correct
        // if we're dealing with smart clients, we need to braodcast this
        // change, since otherwise, their ring will not be in good shape;
        // perhaps, we should keep one version for the slaves, and another
        // for smart clients
        _master->reset_system_state ();

        return;
    }

    switch (sbp->proc ()) {
    case DSDC_GET:
    case DSDC_GET2:
    case DSDC_GET3:
        _master->handle_get (sbp);
        break;
    case DSDC_REMOVE:
        _master->handle_remove (sbp);
        break;
    case DSDC_PUT:
        _master->handle_put (sbp);
        break;
    case DSDC_REGISTER:
        handle_register (sbp);
        break;
    case DSDC_REGISTER2:
        handle_register2(sbp);
        break;
    case DSDC_HEARTBEAT:
        handle_heartbeat (sbp);
        break;
    case DSDC_GETSTATE:
        _master->handle_getstate (sbp);
        break;
    case DSDC_GETSTATE2:
        _master->handle_getstate2(sbp);
        break;
    case DSDC_LOCK_ACQUIRE:
        _master->handle_lock_acquire (sbp);
        break;
    case DSDC_LOCK_RELEASE:
        _master->handle_lock_release (sbp);
        break;
    case DSDC_GET_STATS:
        _master->handle_get_stats (sbp);
        break;
    default:
        sbp->reject (PROC_UNAVAIL);
        break;
    }
}

//-----------------------------------------------------------------------------

void
dsdc_master_t::downgrade_system_state(dsdcx_state_t& dstate,
                                      const dsdcx_state2_t& ustate) {
    dstate.lock_server = ustate.lock_server;
    for (auto s : ustate.slaves) {
        dsdcx_slave_t slave;

        slave.keys = s.keys;
        slave.hostname = s.hostname;
        slave.port = s.port;

        dstate.slaves.push_back(slave);
    }
}

//-----------------------------------------------------------------------------

void
dsdc_master_t::downgrade_slave(dsdcx_slave_t& dslave,
                               const dsdcx_slave2_t& ustate) {
    dslave.keys = ustate.keys;
    dslave.hostname = ustate.hostname;
    dslave.port = ustate.port;
}

//-----------------------------------------------------------------------------

void
dsdc_master_t::upgrade_slave(dsdcx_slave2_t& uslave,
                             const dsdcx_slave_t& dslave) {
    uslave.keys = dslave.keys;
    uslave.hostname = dslave.hostname;
    uslave.port = dslave.port;
    uslave.slave_type = DSDC_NORMAL_SLAVE;
}

//-----------------------------------------------------------------------

void
dsdc_master_t::handle_getstate (svccb *sbp)
{
    timespec ts_start;
    ts_start = sfs_get_tsnow ();

    dsdc_key_t *arg = sbp->Xtmpl getarg<dsdc_key_t> ();
    dsdc_getstate_res_t res (false);
    compute_system_state ();

    if (dsdck_cmp (*arg, *_system_state_hash) != 0) {
        res.set_needupdate (true);
        downgrade_system_state(*res.state, *_system_state);
    }

    get_rpc_stats().end_call (sbp->prog(), sbp->vers(), sbp->proc(), ts_start);
    sbp->replyref (res);
}

//-----------------------------------------------------------------------

void
dsdc_master_t::handle_getstate2 (svccb *sbp)
{
    timespec ts_start;
    ts_start = sfs_get_tsnow ();

    dsdc_key_t *arg = sbp->Xtmpl getarg<dsdc_key_t> ();
    dsdc_getstate2_res_t res (false);
    compute_system_state ();

    if (dsdck_cmp (*arg, *_system_state_hash) != 0) {
        res.set_needupdate (true);
        *res.state = *_system_state;
    }

    get_rpc_stats().end_call (sbp->prog(), sbp->vers(), sbp->proc(), ts_start);
    sbp->replyref (res);
}

//-----------------------------------------------------------------------

void
dsdcm_client_t::handle_heartbeat (svccb *sbp)
{

    timespec ts_start;
    ts_start = sfs_get_tsnow ();
    if (sbp->getsrv ()->xprt ()->ateof ())
        return;

    if (!_slave) {
        sbp->reject (PROC_UNAVAIL);
        return;
    }
    _slave->handle_heartbeat ();

    get_rpc_stats().end_call (sbp->prog(), sbp->vers(), sbp->proc(), ts_start);
    sbp->replyref (DSDC_OK);
}

//-----------------------------------------------------------------------

void
dsdc_master_t::reset_system_state ()
{
    _system_state = NULL;
    _system_state_hash = NULL;
    if (show_debug (DSDC_DBG_HI))
        warn << "system state reset\n";
}

//-----------------------------------------------------------------------

void
dsdc_master_t::compute_system_state ()
{
    // only need to recompute the system state if it was explicitly
    // turned off
    if (_system_state)
        return;

    _system_state = New refcounted<dsdcx_state2_t> ();

    dsdcx_slave2_t slave;
    for (dsdcm_slave_t *p = _slaves.first; p; p = _slaves.next (p)) {
        p->get_xdr_repr (&slave);
        _system_state->slaves.push_back (slave);
    }

    if (_lock_servers.first) {
        if (!_system_state->lock_server)
            _system_state->lock_server.alloc ();
        _lock_servers.first->get_xdr_repr (&slave);
        downgrade_slave(*_system_state->lock_server, slave);
    }

    // also compute the hash
    _system_state_hash = New refcounted<dsdc_key_t> ();
    sha1_hashxdr (_system_state_hash->base (), *_system_state);

}

//-----------------------------------------------------------------------

static str
svccb_to_ip (svccb *sbp)
{
    int fd = sbp->getsrv ()->xprt ()->getreadfd ();
    struct sockaddr_in sin;
    socklen_t sinlen = sizeof (sin);
    str ret;

    if (getpeername (fd, (struct sockaddr *)&sin, &sinlen) != 0) {
        warn ("getpeername failed: %m\n");
    } else {
        const char *ip = inet_ntoa (sin.sin_addr);
        ret = ip;
    }
    return ret;
}

//-----------------------------------------------------------------------

void
dsdcm_client_t::handle_register (svccb *sbp)
{
    timespec ts_start;
    dsdc_register_arg_t *arg = sbp->Xtmpl getarg<dsdc_register_arg_t> ();

    ts_start = sfs_get_tsnow ();
    if (_slave) {
        sbp->replyref (dsdc_res_t (DSDC_ALREADY_REGISTERED));
        return;
    }
    if (arg->lock_server) {
        _slave = dsdcm_lock_server_t::alloc (mkref (this), _x);
    } else {
        _slave = dsdcm_slave_t::alloc (mkref (this), _x);
    }

    // Safer to use the IP that the kernel is giving us, and not the 
    // random hostname that the node supplied. This solves especially
    // bad behavior when the DNS mappings change midstream.
    str ip = svccb_to_ip (sbp);
    if (ip) { 
        arg->slave.hostname = ip;
    }

    dsdcx_slave2_t uslave;

    _master->upgrade_slave(uslave, arg->slave);
    _slave->init (uslave);

    sbp->replyref (dsdc_res_t (DSDC_OK));

    // clear out the state fields since they are no longer correct
    // as an optimization, we only do this on a node addition, and
    // not on a node deletion.  inserting nodes is the problem, since
    // that will cause our cached data to no longer be relevant
    _master->reset_system_state ();

    /*
     * do not kick off the newnode protocol yet; we'll add this
     * back in when there is data movement that we care about.
     *
    if (arg->primary)
      _master->broadcast_newnode (arg->keys, _slave);
    */

    get_rpc_stats().end_call (sbp->prog(), sbp->vers(), sbp->proc(), ts_start);
    return;
}

//-----------------------------------------------------------------------------

void
dsdcm_client_t::handle_register2(svccb* sbp) {

    timespec ts_start;
    dsdc_register2_arg_t *arg = sbp->Xtmpl getarg<dsdc_register2_arg_t> ();

    ts_start = sfs_get_tsnow ();
    if (_slave) {
        sbp->replyref (dsdc_res_t (DSDC_ALREADY_REGISTERED));
        return;
    }
    if (arg->lock_server) {
        _slave = dsdcm_lock_server_t::alloc (mkref (this), _x);
    } else {
        switch (arg->slave.slave_type) {
        case DSDC_NORMAL_SLAVE:
            _slave = dsdcm_slave_t::alloc (mkref (this), _x);
            break;
        case DSDC_REDIS_SLAVE:
            _slave = dsdcm_redis_slave_t::alloc (mkref (this), _x);
            break;
        default:
            warn << "dsdc_error: handle_register2(): unknown slave type: "
                 << arg->slave.slave_type << "\n";
            sbp->replyref(DSDC_NONODE);
            return;
        };

    }

    // Safer to use the IP that the kernel is giving us, and not the 
    // random hostname that the node supplied. This solves especially
    // bad behavior when the DNS mappings change midstream.
    str ip = svccb_to_ip (sbp);
    if (ip) { 
        arg->slave.hostname = ip;
    }

    _slave->init(arg->slave);

    sbp->replyref (dsdc_res_t (DSDC_OK));

    // clear out the state fields since they are no longer correct
    // as an optimization, we only do this on a node addition, and
    // not on a node deletion.  inserting nodes is the problem, since
    // that will cause our cached data to no longer be relevant
    _master->reset_system_state ();

    /*
     * do not kick off the newnode protocol yet; we'll add this
     * back in when there is data movement that we care about.
     *
    if (arg->primary)
      _master->broadcast_newnode (arg->keys, _slave);
    */

    get_rpc_stats().end_call (sbp->prog(), sbp->vers(), sbp->proc(), ts_start);

    return;

}

//-----------------------------------------------------------------------

void
dsdcm_client_t::release ()
{
    _master->remove_client (this);

    // This code here should cause the object pointed to by _slave
    // to be released.  The first call will clear all references to the
    // slave in the dsdc_ring, and the second call will clear our 
    // reference to it.  Usually those are the only things holding it up.
    if (_slave) {
        _slave->release ();
        _slave = NULL;
    }

    refcount_dec ();
}

//-----------------------------------------------------------------------

void
dsdcm_slave_t::insert_node (dsdc_master_t *m, dsdc_ring_node_t *n)
{
    m->insert_node (n);
}

//-----------------------------------------------------------------------

void
dsdcm_lock_server_t::insert_node (dsdc_master_t *m, dsdc_ring_node_t *n)
{
    m->insert_lock_node (n);
}

//-----------------------------------------------------------------------

void
dsdcm_slave_base_t::insert_nodes ()
{
    for (u_int i = 0; i < _xdr_repr.keys.size (); i++) {

        dsdc_key_t k = _xdr_repr.keys[i];
        dsdc_ring_node_t *n = New dsdc_ring_node_t (mkref (this), k);

        insert_node (_client->get_master (), n);
        _nodes.push_back (n);

        if (show_debug (DSDC_DBG_LOW)) {
            warn ("insert slave: %s -> %s(%p)\n",
                  key_to_str (k).cstr (), remote_peer_id ().cstr (), this);
        }
    }
}

//-----------------------------------------------------------------------

void
dsdcm_slave_base_t::init (const dsdcx_slave2_t &sl)
{
    _xdr_repr = sl;
    insert_nodes ();

    // need this just once
    handle_heartbeat ();
}

//-----------------------------------------------------------------------

void
dsdcm_slave_t::remove_node (dsdc_master_t *m, dsdc_ring_node_t *rn)
{
    m->remove_node (rn);
}

//-----------------------------------------------------------------------

void
dsdcm_lock_server_t::remove_node (dsdc_master_t *m, dsdc_ring_node_t *rn)
{
    m->remove_lock_node (rn);
}

//-----------------------------------------------------------------------

void
dsdcm_slave_base_t::remove_nodes ()
{
    for (u_int i = 0; i < _nodes.size (); i++) {
        dsdc_ring_node_t *n = _nodes[i];
        remove_node (_client->get_master (), n);
        if (show_debug (DSDC_DBG_LOW)) {
            warn ("removing node %s -> %s (%p)\n",
                  key_to_str (n->_key).cstr (), 
                  remote_peer_id ().cstr (), this);
        }
        delete n;
    }
}

//-----------------------------------------------------------------------

tamed void
dsdc_master_t::get_connection (const dsdc_key_t &k, ptr<connection_t> *cli,
                               event<dsdc_res_t>::ref ev)
{

    tvars {
        dsdc_ring_node_t *node; 
        connection_wrap_t* w;
    }

    node = _hash_ring.successor (k);
    if (!node) {
        ev->trigger(DSDC_NONODE);
        return;
    }

    w = node->get_connection_wrap ();
    assert (w);
    if (show_debug (DSDC_DBG_MED))
        warn ("resolved mapping: %s -> %s (%p)\n",
              key_to_str (k).cstr (), w->remote_peer_id ().cstr (), w);

    if (w->is_dead ()) {
        ev->trigger(DSDC_DEAD);
        return;
    }

    twait { w->get_connection(mkevent(*cli)); }

    ev->trigger(DSDC_OK);
}

//-----------------------------------------------------------------------

bool
dsdcm_slave_base_t::is_dead ()
{
    if (sfs_get_timenow () - _last_heartbeat >
        dsdc_heartbeat_interval * dsdc_missed_beats_to_death) {
        if (show_debug (DSDC_DBG_LOW)) {
            warn ("detected dead slave: %s\n", remote_peer_id ().cstr ());
        }
        release ();
        return true;
    }
    return false;
}

//-----------------------------------------------------------------------

static void
handle_vanilla_cb (ptr<int> res, svccb *sbp, clnt_stat err)
{
    if (sbp->getsrv ()->xprt ()->ateof ())
        return;
    if (err)
        *res = DSDC_RPC_ERROR;
    sbp->reply (res);
}

//-----------------------------------------------------------------------

tamed void
dsdc_master_t::handle_get (svccb *sbp)
{
    tvars {
        const dsdc_get_arg_t *a1;
        const dsdc_req_t *a2;
        const dsdc_get3_arg_t *a3;
        const void *av (NULL);
        dsdc_get_res_t res;
        ptr<connection_t> cli;
        dsdc_res_t r;
        clnt_stat err;
        dsdc_key_t key;
    }

    switch (sbp->proc ()) {
    case DSDC_GET:
        a1 = sbp->Xtmpl getarg<dsdc_get_arg_t> ();
        key = *a1;
        av = a1;
        break;
    case DSDC_GET2:
        a2 = sbp->Xtmpl getarg<dsdc_req_t> ();
        av = a2;
        key = a2->key;
        break;
    case DSDC_GET3:
        a3 = sbp->Xtmpl getarg<dsdc_get3_arg_t> ();
        av = a3;
        key = a3->key;
        break;
    default:
        panic ("Unexpected key; shouldn't be here.\n");
        break;
    }

    twait { get_connection(key, &cli, mkevent(r)); }

    if (r != DSDC_OK) {
        res.set_status (r);
    } else {
        twait { cli->call (sbp->proc (), av, &res, mkevent (err)); }
        if (err)
            res.set_status (DSDC_RPC_ERROR);
    }

    if (!sbp->getsrv ()->xprt ()->ateof ())
        sbp->replyref (res);
}

//-----------------------------------------------------------------------

static void
acquire_cb (svccb *sbp, ptr<dsdc_lock_acquire_res_t> res, clnt_stat stat)
{
    if (!stat) {
        res->set_status (DSDC_RPC_ERROR);
        *res->err = stat;
    } else {
        sbp->reply (res);
    }
}

//-----------------------------------------------------------------------

void
dsdc_master_t::handle_lock_release (svccb *sbp)
{
    if (!lock_server ()) {
        sbp->replyref (DSDC_NONODE);
    } else {
        ptr<int> res = New refcounted<int> ();
        lock_server ()->get_connection ()->
        call (DSDC_LOCK_RELEASE,
              sbp->Xtmpl getarg<dsdc_lock_release_arg_t> (),
              res,
              wrap (handle_vanilla_cb, res, sbp));
    }
}

//-----------------------------------------------------------------------

void
dsdc_master_t::handle_lock_acquire (svccb *sbp)
{
    ptr<dsdc_lock_acquire_res_t> res
    = New refcounted<dsdc_lock_acquire_res_t> ();
    if (!lock_server ()) {
        res->set_status (DSDC_NONODE);
        sbp->reply (res);
    } else {
        lock_server ()->get_connection ()->
        call (DSDC_LOCK_ACQUIRE,
              sbp->Xtmpl getarg<dsdc_lock_acquire_arg_t> (),
              res, wrap (acquire_cb, sbp, res));
    }
}

//-----------------------------------------------------------------------

tamed void
dsdc_master_t::handle_remove (svccb *sbp)
{
    tvars {
        dsdc_key_t *k (sbp->Xtmpl getarg<dsdc_key_t> ());
        ptr<connection_t> cli;
        dsdc_res_t res;
        clnt_stat err;
    }

    twait { get_connection (*k, &cli, mkevent(res)); }
    if (res == DSDC_OK) {
        twait {
            cli->call(DSDC_REMOVE, k, &res, mkevent(err));
        }
        if (err)
            res = DSDC_RPC_ERROR;
    }

    if (!sbp->getsrv ()->xprt ()->ateof ())
        sbp->replyref (res);
}

//-----------------------------------------------------------------------

tamed void
dsdc_master_t::handle_put (svccb *sbp)
{
    tvars {
        dsdc_put_arg_t *arg (sbp->Xtmpl getarg<dsdc_put_arg_t> ());
        ptr<connection_t> cli;
        dsdc_res_t res;
        clnt_stat err;
    }
    twait { get_connection (arg->key, &cli, mkevent(res)); }
    if (res == DSDC_OK) {
        twait {
            cli->call(DSDC_PUT, arg, &res, mkevent(err));
        }
        if (err)
            res = DSDC_RPC_ERROR;
    }
    if (!sbp->getsrv ()->xprt ()->ateof ())
        sbp->replyref (res);
}

//-----------------------------------------------------------------------

//
// broadcast_newnode; not in use currently.  we're going to
// use this to kick off the data movement protocol if we decide
// this is the right thing to do.
//
tamed void
dsdc_master_t::broadcast_newnode (const dsdcx_slave_t &x, dsdcm_slave_t *skip)
{
    tvars {
        dsdcm_slave_t *p;
        dsdc_res_t dummy;
        clnt_stat err;
    }

    twait {
        for (p = _slaves.first; p; p = _slaves.next (p)) {
            if (p != skip && !p->is_dead ()) {
                RPC::dsdc_prog_1::dsdc_newnode (p->get_aclnt(), x, &dummy,
                                                mkevent (err));
            }
        }
    }
}

//-----------------------------------------------------------------------

void
dsdc_master_t::insert_lock_server (dsdcm_lock_server_t *ls)
{
    int debug_lev = 1;
    str typ;
    if (_lock_servers.first) {
        debug_lev = 2;
        typ = "BACKUP";
    } else {
        typ = "primary";
    }
    _lock_servers.insert_tail (ls);
    if (show_debug (debug_lev)) {
        warn ("%s lock server registered: %s(%p)\n",
              typ.cstr (), ls->remote_peer_id ().cstr (), this);
    }
}

//-----------------------------------------------------------------------

void
dsdc_master_t::check_all_slaves ()
{
    dsdcm_slave_t *sl;
    dsdcm_lock_server_t *ls;
    bool rst = false;
    for (sl = _slaves.first; sl; sl = _slaves.next (sl)) {
        if (sl->is_dead ())
            rst = true;
    }
    for (ls = _lock_servers.first; ls; ls = _lock_servers.next (ls)) {
        if (ls->is_dead ())
            rst = true;
    }
    if (rst)
        reset_system_state ();
}

//-----------------------------------------------------------------------

tamed void
dsdc_master_t::watchdog_timer_loop ()
{
    while (true) {
        check_all_slaves ();
        twait { delaycb (dsdcm_timer_interval, 0, mkevent ()); }
    }
}

//-----------------------------------------------------------------------

tamed void
dsdc_master_t::get_stats (dsdc_slave_statistic_t *out,
                          const dsdc_get_stats_single_arg_t *arg,
                          dsdcm_slave_t *sl, cbv cb)
{
    tvars {
        clnt_stat err;
        ptr<connection_t> c;
    }
    out->host = sl->remote_peer_id ();
    c = sl->get_connection ();
    if (!c) {
        out->stats.set_status (DSDC_DEAD);
    } else {
        twait { 
            c->call (DSDC_GET_STATS_SINGLE, arg, &out->stats, mkevent (err)); 
        }
        if (err) {
            out->stats.set_status (DSDC_RPC_ERROR);
            warn << __func__ << ": DSDC RPC ERROR [" << out->host
            << "]: " << err << "\n";
        }
    }
    DSDC_SIGNAL (cb);
}

//-----------------------------------------------------------------------

tamed void
dsdc_master_t::handle_get_stats (svccb *sbp)
{
    tvars {
        dsdc_get_stats_arg_t *a;
        dsdc_slave_statistics_t res;
        dsdcm_slave_t *sl, *p;
        u_int r, max;
        size_t s, i;
        str nm;
    }
    a = sbp->Xtmpl getarg<dsdc_get_stats_arg_t> ();
    switch (a->hosts.typ) {
    case DSDC_SET_FIRST:
    case DSDC_SET_RANDOM:
    {
        max = 0;
        for (sl = p = _slaves.first; p && a->hosts.typ != DSDC_SET_FIRST;
             p = _slaves.next (p)) {
            if ((r = rand ()) >= max) {
                max = r;
                sl = p;
            }
        }
        if (sl) {
            res.setsize (1);
            twait { get_stats (&res[0], &a->getparams, sl, mkevent ()); }
        } else {
            res.setsize (0);
        }
        break;
    }
    case DSDC_SET_SOME:
    {
        s = a->hosts.some->size ();
        res.setsize (s);
        twait {
            for (i = 0; i < s; i++) {
                nm = (*a->hosts.some)[i];
                if ((p = _slave_hash[nm])) {
                    get_stats (&res[i], &a->getparams, p, mkevent ());
                } else {
                    res[i].host = nm;
                    res[i].stats.set_status (DSDC_NOTFOUND);
                }
            }
        }
        break;
    }
    case DSDC_SET_ALL:
    {
        res.setsize (_n_slaves);
        twait {
            for (p = _slaves.first; p; p = _slaves.next (p)) {
                get_stats (&res[0], &a->getparams, p, mkevent ());
            }
        }
        break;
    }
    default:
        break;
    }
    if (!sbp->getsrv ()->xprt ()->ateof ())
        sbp->replyref (res);
}

//-----------------------------------------------------------------------

