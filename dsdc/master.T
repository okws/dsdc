// -*-c++-*-

#include "dsdc_master.h"
#include "crypt.h"
#include "tame.h"
#include "dsdc_signal.h"

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

  // check periodically that nothing died on us with a bad heart.
  watchdog_timer ();
  return true;
}

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
    vNew dsdcm_client_t (this, nfd, hn);

  } else if (errno != EAGAIN)
    warn ("accept failed: %m\n");
}

dsdcm_client_t::dsdcm_client_t (dsdc_master_t *ma, int f, const str &h)
  : _slave (NULL), _master (ma), _fd (f), _hostname (h)
{
  tcp_nodelay (_fd);
  _x = axprt_stream::alloc (_fd, dsdc_packet_sz);
  _asrv = asrv::alloc (_x, dsdc_prog_1, 
		       wrap (this, &dsdcm_client_t::dispatch));
  _master->insert_client (this);
}

dsdcm_slave_base_t::dsdcm_slave_base_t (dsdcm_client_t *c, ptr<axprt> x)
  : _client (c), _clnt_to_slave (aclnt::alloc (x, dsdc_prog_1))
{
  // start them up with a heartbeat so not deleted right away!
  handle_heartbeat ();
}  

dsdcm_slave_t::dsdcm_slave_t (dsdcm_client_t *c, ptr<axprt> x)
  : dsdcm_slave_base_t (c, x)
{
  _client->get_master ()->insert_slave (this);
}

dsdcm_lock_server_t::dsdcm_lock_server_t (dsdcm_client_t *c, ptr<axprt> x)
  : dsdcm_slave_base_t (c, x)
{
  _client->get_master ()->insert_lock_server (this);
}

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
    delete this;  

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
  case DSDC_HEARTBEAT:
    handle_heartbeat (sbp);
    break;
  case DSDC_GETSTATE:
    _master->handle_getstate (sbp);
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

void
dsdc_master_t::handle_getstate (svccb *sbp)
{
  dsdc_key_t *arg = sbp->Xtmpl getarg<dsdc_key_t> ();
  dsdc_getstate_res_t res (false);
  compute_system_state ();
 
  if (dsdck_cmp (*arg, *_system_state_hash) != 0) {
    res.set_needupdate (true);
    *res.state = *_system_state;
  }
  sbp->replyref (res);
}


void
dsdcm_client_t::handle_heartbeat (svccb *sbp)
{
  if (sbp->getsrv ()->xprt ()->ateof ())
    return;

  if (!_slave) {
    sbp->reject (PROC_UNAVAIL);
    return;
  } 
  _slave->handle_heartbeat ();
  sbp->replyref (DSDC_OK);
}

void
dsdc_master_t::reset_system_state ()
{
  _system_state = NULL;
  _system_state_hash = NULL;
  if (show_debug (DSDC_DBG_HI))
    warn << "system state reset\n";
}

void
dsdc_master_t::compute_system_state ()
{
  // only need to recompute the system state if it was explicitly
  // turned off
  if (_system_state) 
    return;

  _system_state = New refcounted<dsdcx_state_t> ();

  dsdcx_slave_t slave;
  for (dsdcm_slave_t *p = _slaves.first; p; p = _slaves.next (p)) {
    p->get_xdr_repr (&slave);
    _system_state->slaves.push_back (slave);
  }

  if (_lock_servers.first) {
    if (!_system_state->lock_server)
      _system_state->lock_server.alloc ();
    _lock_servers.first->get_xdr_repr (&slave);
    *_system_state->lock_server = slave;
  }

  // also compute the hash 
  _system_state_hash = New refcounted<dsdc_key_t> ();
  sha1_hashxdr (_system_state_hash->base (), *_system_state);
  
}


void
dsdcm_client_t::handle_register (svccb *sbp)
{
  dsdc_register_arg_t *arg = sbp->Xtmpl getarg<dsdc_register_arg_t> ();
  if (_slave) {
    sbp->replyref (dsdc_res_t (DSDC_ALREADY_REGISTERED));
    return;
  }
  if (arg->lock_server) {
    _slave = New dsdcm_lock_server_t (this, _x);
  } else {
    _slave = New dsdcm_slave_t (this, _x);
  }
  _slave->init (arg->slave);
  
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

  return;
}

dsdcm_client_t::~dsdcm_client_t ()
{
  _master->remove_client (this);
  if (_slave)
    delete _slave;
}

void
dsdcm_slave_t::insert_node (dsdc_master_t *m, dsdc_ring_node_t *n)
{
  m->insert_node (n);
}

void
dsdcm_lock_server_t::insert_node (dsdc_master_t *m, dsdc_ring_node_t *n)
{
  m->insert_lock_node (n);
}


void
dsdcm_slave_base_t::insert_nodes ()
{
  for (u_int i = 0; i < _xdr_repr.keys.size (); i++) {

    dsdc_key_t k = _xdr_repr.keys[i];
    dsdc_ring_node_t *n = New dsdc_ring_node_t (this, k);
   
    insert_node (_client->get_master (), n);
    _nodes.push_back (n);

    if (show_debug (DSDC_DBG_LOW)) {
      warn ("insert slave: %s -> %s(%p)\n", 
	    key_to_str (k).cstr (), remote_peer_id ().cstr (), this);
    }
  }
}

void
dsdcm_slave_base_t::init (const dsdcx_slave_t &sl)
{
  _xdr_repr = sl;
  insert_nodes ();

  // need this just once
  handle_heartbeat ();
}

dsdcm_slave_t::~dsdcm_slave_t ()
{
  _client->get_master ()->remove_slave (this);
  remove_nodes ();
}

dsdcm_lock_server_t::~dsdcm_lock_server_t ()
{
  _client->get_master ()->remove_lock_server (this);
  remove_nodes ();
}

void
dsdcm_slave_t::remove_node (dsdc_master_t *m, dsdc_ring_node_t *rn)
{
  m->remove_node (rn);
}

void
dsdcm_lock_server_t::remove_node (dsdc_master_t *m, dsdc_ring_node_t *rn)
{
  m->remove_lock_node (rn);
}

void
dsdcm_slave_base_t::remove_nodes ()
{
  for (u_int i = 0; i < _nodes.size (); i++) {
    dsdc_ring_node_t *n = _nodes[i];
    remove_node (_client->get_master (), n);
    if (show_debug (DSDC_DBG_LOW)) {
      warn ("removing node %s -> %s (%p)\n",
	    key_to_str (n->_key).cstr (), remote_peer_id ().cstr (), this);
    }
    delete n;
  }
}

dsdc_res_t
dsdc_master_t::get_aclnt (const dsdc_key_t &k, ptr<aclnt> *cli)
{
  dsdc_ring_node_t *node = _hash_ring.successor (k);
  if (!node)
    return DSDC_NONODE;

  aclnt_wrap_t *w = node->get_aclnt_wrap ();
  assert (w);
  if (show_debug (DSDC_DBG_MED)) 
    warn ("resolved mapping: %s -> %s (%p)\n", 
	  key_to_str (k).cstr (), w->remote_peer_id ().cstr (), w);
  
  if (w->is_dead ()) {
    return DSDC_DEAD;
  }
  *cli = w->get_aclnt ();
  return DSDC_OK;
}

bool
dsdcm_slave_base_t::is_dead ()
{
  if (sfs_get_timenow () - _last_heartbeat > 
      dsdc_heartbeat_interval * dsdc_missed_beats_to_death) {
    if (show_debug (DSDC_DBG_LOW)) {
      warn ("detected dead slave: %s\n", remote_peer_id ().cstr ());
    }
    delete this;
    return true;
  }
  return false;
}

static void
handle_vanilla_cb (ptr<int> res, svccb *sbp, clnt_stat err)
{
  if (sbp->getsrv ()->xprt ()->ateof ())
    return;
  if (err) 
    *res = DSDC_RPC_ERROR;
  sbp->reply (res);
}

tamed void
dsdc_master_t::handle_get (svccb *sbp)
{
  tvars {
    const dsdc_get_arg_t *a1;
    const dsdc_req_t *a2;
    const dsdc_get3_arg_t *a3;
    const void *av (NULL);
    dsdc_get_res_t res;
    ptr<aclnt> cli;
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
    
  if ((r = get_aclnt (key, &cli)) != DSDC_OK) {
    res.set_status (r);
  } else {
    twait { cli->call (sbp->proc (), av, &res, mkevent (err)); }
    if (err) 
      res.set_status (DSDC_RPC_ERROR);
  }
  
  if (!sbp->getsrv ()->xprt ()->ateof ()) 
    sbp->replyref (res);
}

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

void
dsdc_master_t::handle_lock_release (svccb *sbp)
{
  if (!lock_server ()) {
    sbp->replyref (DSDC_NONODE);
  } else {
    ptr<int> res = New refcounted<int> ();
    lock_server ()->get_aclnt ()->
      call (DSDC_LOCK_RELEASE,
	    sbp->Xtmpl getarg<dsdc_lock_release_arg_t> (),
	    res,
	    wrap (handle_vanilla_cb, res, sbp));
  }
}

void
dsdc_master_t::handle_lock_acquire (svccb *sbp)
{
  ptr<dsdc_lock_acquire_res_t> res
    = New refcounted<dsdc_lock_acquire_res_t> ();
  if (!lock_server ()) {
    res->set_status (DSDC_NONODE);
    sbp->reply (res);
  } else {
    lock_server ()->get_aclnt ()-> 
      call (DSDC_LOCK_ACQUIRE, 
	    sbp->Xtmpl getarg<dsdc_lock_acquire_arg_t> (),
	    res, wrap (acquire_cb, sbp, res));
  }
}

tamed void
dsdc_master_t::handle_remove (svccb *sbp)
{
  tvars {
    dsdc_key_t *k (sbp->Xtmpl getarg<dsdc_key_t> ());
    ptr<aclnt> cli;
    dsdc_res_t res;
    clnt_stat err;
  }

  res = get_aclnt (*k, &cli);
  if (res == DSDC_OK) {
    twait { 
      RPC::dsdc_prog_1::dsdc_remove (cli, k, &res, mkevent(err)); 
    }
    if (err) 
      res = DSDC_RPC_ERROR;
  }

  if (!sbp->getsrv ()->xprt ()->ateof ()) 
    sbp->replyref (res);
}

tamed void
dsdc_master_t::handle_put (svccb *sbp)
{
  tvars {
    dsdc_put_arg_t *arg (sbp->Xtmpl getarg<dsdc_put_arg_t> ());
    ptr<aclnt> cli;
    dsdc_res_t res;
    clnt_stat err;
  }
  res = get_aclnt (arg->key, &cli);
  if (res == DSDC_OK) {
    twait { 
      RPC::dsdc_prog_1::dsdc_put (cli, arg, &res, mkevent (err));
    }
    if (err)
      res = DSDC_RPC_ERROR;
  }
  if (!sbp->getsrv ()->xprt ()->ateof ()) 
    sbp->replyref (res);
}


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

void 
dsdc_master_t::watchdog_timer ()
{
  check_all_slaves ();
  // XXX hard-coded constant of 5 in there for now.
  _tmr = delaycb (5, 0, wrap (this, &dsdc_master_t::watchdog_timer));
}

tamed void
dsdc_master_t::get_stats (dsdc_slave_statistic_t *out,
			  const dsdc_get_stats_single_arg_t *arg,
			  dsdcm_slave_t *sl, cbv cb)
{
  tvars {
    clnt_stat err;
    ptr<aclnt> c;
  }
  out->host = sl->remote_peer_id ();
  c = sl->get_aclnt ();
  if (!c) {
    out->stats.set_status (DSDC_DEAD);
  } else {
    twait { c->call (DSDC_GET_STATS_SINGLE, arg, &out->stats, mkevent (err)); }
    if (err) {
      out->stats.set_status (DSDC_RPC_ERROR);
      warn << __func__ << ": DSDC RPC ERROR [" << out->host 
	   << "]: " << err << "\n";
    }
  }
  DSDC_SIGNAL (cb);
}

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
