#include "dsdc_master.h"
#include "crypt.h"

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

dsdcm_slave_t::dsdcm_slave_t (dsdcm_client_t *c, ptr<axprt> x) :
  _client (c), _clnt_to_slave (aclnt::alloc (x, dsdc_prog_1)) 
{
  _client->get_master ()->insert_slave (this);
}

void
dsdcm_client_t::dispatch (svccb *sbp)
{
  if (!sbp) {

    warn << "client " << hostname () << " gave EOF\n";

    // at the enf of a TCP connection, we get a NULL sbp from SFS.
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
    *res.slaves = *_system_state;
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
  sbp->reply (NULL);
}

void
dsdc_master_t::reset_system_state ()
{
  _system_state = NULL;
  _system_state_hash = NULL;
}

void
dsdc_master_t::compute_system_state ()
{
  // only need to recompute the system state if it was explicitly
  // turned off
  if (_system_state) 
    return;

  _system_state = New refcounted<dsdcx_slaves_t> ();

  dsdcx_slave_t slave;
  for (dsdcm_slave_t *p = _slaves.first; p; p = _slaves.next (p)) {
    p->get_xdr_repr (&slave);
    _system_state->slaves.push_back (slave);
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
  _slave = New dsdcm_slave_t (this, _x);
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
dsdcm_slave_t::init (const dsdcx_slave_t &sl)
{
  for (u_int i = 0; i < sl.keys.size (); i++) {

    dsdc_ring_node_t *n = New dsdc_ring_node_t (this, sl.keys[i]);
    _client->get_master ()->insert_node (n);
    _nodes.push_back (n);

    if (show_debug (1)) {
      warn ("insert slave: %s -> %s(%p)\n", 
	    key_to_str (sl.keys[i]).cstr (), 
	    _client->hostname ().cstr (), this);
    }
  }

  _xdr_repr = sl;

  // need this just once
  handle_heartbeat ();
}

dsdcm_slave_t::~dsdcm_slave_t ()
{
  _client->get_master ()->remove_slave (this);
  for (u_int i = 0; i < _nodes.size (); i++) {
    _client->get_master ()->remove_node (_nodes[i]);
    if (show_debug (1)) {
      warn ("removing node %s -> %s (%p)\n",
	    key_to_str (_nodes[i]->_key).cstr (),
	    hostname ().cstr (), this);
    }
    delete _nodes[i];
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
  if (show_debug (2)) 
    warn ("resolved mapping: %s -> %s (%p)\n", 
	  key_to_str (k).cstr (), w->hostname ().cstr (), w);
  
  if (w->is_dead ()) {
    return DSDC_DEAD;
  }
  *cli = w->get_aclnt ();
  return DSDC_OK;
}

bool
dsdcm_slave_t::is_dead ()
{
  if (timenow - _last_heartbeat > 
      dsdc_heartbeat_interval * dsdc_missed_beats_to_death) {
    delete this;
    return true;
  }
  return false;
}

static void 
handle_get_cb (ptr<dsdc_get_res_t> res, svccb *sbp, clnt_stat err)
{
  if (sbp->getsrv ()->xprt ()->ateof ())
    return;
  if (err) 
    res->set_status (DSDC_RPC_ERROR);
  sbp->reply (res);
}

static void
handle_vanilla_cb (ptr<int> res, svccb *sbp, clnt_stat err)
{
  if (sbp->getsrv ()->xprt ()->ateof ())
    return;
  if (err) 
    *res =  DSDC_RPC_ERROR;
  sbp->reply (res);
}

void
dsdc_master_t::handle_get (svccb *sbp)
{
  dsdc_key_t *k = sbp->Xtmpl getarg<dsdc_key_t> ();
  ptr<dsdc_get_res_t> res = New refcounted<dsdc_get_res_t> ();
  ptr<aclnt> cli;

  dsdc_res_t r = get_aclnt (*k, &cli);
  if (r != DSDC_OK) {
    res->set_status (r);
    sbp->reply (res);
  } else 
    cli->call (DSDC_GET, k, res, wrap (handle_get_cb, res, sbp));
}

void
dsdc_master_t::handle_remove (svccb *sbp)
{
  dsdc_key_t *k = sbp->Xtmpl getarg<dsdc_key_t> ();
  ptr<aclnt> cli;
  dsdc_res_t r = get_aclnt (*k, &cli);
  if (r != DSDC_OK) {
    sbp->replyref (r);
  } else {
    ptr<int> res = New refcounted<int> ();
    cli->call (DSDC_REMOVE, k, res, wrap (handle_vanilla_cb, res, sbp));
  }
}

void
dsdc_master_t::handle_put (svccb *sbp)
{
  dsdc_put_arg_t *arg = sbp->Xtmpl getarg<dsdc_put_arg_t> ();
  ptr<aclnt> cli;
  dsdc_res_t r = get_aclnt (arg->key, &cli);
  if (r != DSDC_OK) {
    sbp->replyref (r);
  } else {
    ptr<int> res = New refcounted<int> ();
    cli->call (DSDC_PUT, arg, res, wrap (handle_vanilla_cb, res, sbp));
  }
}

static void
ignore_cb (ptr<int> res, clnt_stat err)
{
  /* no op for now */
}

//
// broadcast_newnode; not in use currently.  we're going to 
// use this to kick off the data movement protocol if we decide
// this is the right thing to do.
//
void
dsdc_master_t::broadcast_newnode (const dsdc_keyset_t &k, dsdcm_slave_t *skip)
{
  dsdcx_slave_t arg;

  //
  // XXX eventually let's fill in hostname port so that other nodes can
  // move data to the new node.  This will increase cache hits, especially
  // after a node join.  For now, let's keep it simple.
  //
  arg.keys = k;
  arg.hostname = "not used";
  arg.port = 0;

  for (dsdcm_slave_t *p = _slaves.first; p; p = _slaves.next (p)) {
    if (p != skip && !p->is_dead ()) {
      ptr<int> res = New refcounted<int> ();
      p->get_aclnt ()->call (DSDC_NEWNODE, &arg, res, 
			     wrap (ignore_cb, res));
    }
  }
}

//
// broadcast_deletes; now depricated, in favor of reconciling membership
// when new nodes are added.
//
void
dsdc_master_t::broadcast_deletes (const dsdc_key_t &k, dsdcm_slave_t *skip)
{
  for (dsdcm_slave_t *p = _slaves.first; p; p = _slaves.next (p)) {
    if (p != skip && !p->is_dead ()) {
      ptr<int> res = New refcounted<int> ();
      p->get_aclnt ()->call (DSDC_REMOVE, &k, res, 
			     wrap (ignore_cb, res));
    }
  }
}

