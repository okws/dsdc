
#include "dsdc_slave.h"
#include "dsdc_const.h"
#include "dsdc_prot.h"
#include "crypt.h"

void
dsdc_cache_obj_t::set (const dsdc_key_t &k, const dsdc_obj_t &o)
{
  _key = k;
  _obj = o;
}


void
dsdcs_master_t::connect_cb (int f)
{
  if (f < 0) {
    went_down (strbuf ("could not connect to host on startup: %m"));
    return;
  }
  master_warn ("connection succeeded");
  _fd = f;
  assert ((_x = axprt_stream::alloc (_fd, dsdc_packet_sz)));
  _cli = aclnt::alloc (_x, dsdc_prog_1);
  _srv = asrv::alloc (_x, dsdc_prog_1, wrap (this, &dsdcs_master_t::dispatch));
  _status = MASTER_STATUS_UP;

  do_register ();
}

void
dsdcs_master_t::do_register_cb (ptr<int> res, clnt_stat err)
{
  if (err) {
    strbuf b;
    b << "Register failed: " << err ;
    went_down (b);
  } else if (*res != DSDC_OK) {
    went_down (strbuf ("register returned error message %d", *res));
  } else {
    ready_to_serve ();
  }
}

void
dsdcs_master_t::ready_to_serve ()
{
  _status = MASTER_STATUS_OK;
  schedule_heartbeat ();
}

void
dsdcs_master_t::heartbeat ()
{
  if (_status == MASTER_STATUS_OK && _cli) {
    _cli->call (DSDC_HEARTBEAT, NULL, NULL, aclnt_cb_null);
    schedule_heartbeat ();
  }
}

void
dsdcs_master_t::schedule_heartbeat ()
{
  delaycb (dsdc_heartbeat_interval, 0, 
	   wrap (this, &dsdcs_master_t::heartbeat));
}

ptr<aclnt>
dsdc_slave_t::get_primary ()
{
  for (dsdcs_master_t *m = _masters.first; m ; m = _masters.next (m)) {
    if (m->status () == MASTER_STATUS_OK)
      return m->cli ();
  }
  return NULL;
}


void
dsdc_slave_t::clean_cache ()
{
  dsdc_cache_obj_t *p, *n;
  size_t tot = 0;
  int nobj = 0;
  for (p = _lru.first; p; p = n) {
    n = _lru.next (p);
    dsdc_ring_node_t *n = _hash_ring.successor (p->_key);
    if (!_khash[n->_key]) {
      if (show_debug (2)) {
	warn ("CLEAN: removed object: %s\n", key_to_str (p->_key).cstr () );
      }
      tot += lru_remove_obj (p, true);
      nobj ++;
    }
  }
  _n_updates_since_clean = 0;
  if (show_debug (1)) 
    warn ("CLEAN: cleaned %d objects (%d bytes in total)\n", nobj, tot);
}

void
dsdcs_master_t::do_register ()
{
  ptr<int> res = New refcounted<int> ();
  dsdc_register_arg_t arg;
  _slave->get_xdr_repr (&arg.slave);
  arg.primary = _primary;
  _cli->call (DSDC_REGISTER, &arg, res,
	      wrap (this, &dsdcs_master_t::do_register_cb, res));
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
    warn << "EOF from " << _hn << "\n";
    delete (this);
  } else
    _parent->dispatch (sbp);
}

void
dsdc_slave_t::dispatch (svccb *sbp)
{
  switch (sbp->proc ()) {
  case DSDC_GET:
    handle_get (sbp);
    break;
  case DSDC_MGET:
    handle_mget (sbp);
    break;
  case DSDC_PUT:
    handle_put (sbp);
    break;
  case DSDC_REMOVE:
    handle_remove (sbp);
    break;
  case DSDC_CUSTOM:
    handle_custom (sbp);
    break;
  default:
    sbp->reject (PROC_UNAVAIL);
    break;
  }
}

// XXX copy + paste from master.C
void
dsdc_slave_t::new_connection ()
{
  sockaddr_in sin;
  bzero (&sin, sizeof (sin));
  socklen_t sinlen = sizeof (sin);
  int nfd = accept (_lfd, reinterpret_cast<sockaddr *> (&sin), &sinlen);
  if (nfd >= 0) {
    strbuf hn ("%s:%d", inet_ntoa (sin.sin_addr), sin.sin_port);
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
dsdcs_master_t::went_down (const str &why)
{
  _x = NULL;
  _cli = NULL;
  _srv = NULL;

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
  dsdc_mget_arg_t *arg = sbp->Xtmpl getarg<dsdc_mget_arg_t> ();
  dsdc_mget_res_t res;
  u_int sz = arg->size ();
  res.setsize (sz);

  for (u_int i = 0; i < sz; i++) {
    dsdc_key_t k = (*arg)[i];
    dsdc_obj_t *o = lru_lookup ( k );
    res[i].key = k;
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
  dsdc_key_t *k = sbp->Xtmpl getarg<dsdc_key_t> ();
  dsdc_obj_t *o = lru_lookup (*k);
  dsdc_get_res_t res;
  if (o) {
    res.set_status (DSDC_OK);
    *res.obj = *o; // XXX might need to copy
  } else {
    res.set_status (DSDC_NOTFOUND);
  }
  sbp->replyref (res);
}

void
dsdc_slave_t::handle_remove (svccb *sbp)
{
  dsdc_key_t *k = sbp->Xtmpl getarg<dsdc_key_t> ();
  dsdc_res_t res;
  if (lru_remove (*k)) {
    res = DSDC_OK;
  } else {
    res = DSDC_NOTFOUND;
  }
  if (show_debug (1)) {
    warn ("remove issued (rc=%d): %s\n", res, key_to_str (*k).cstr ());
  }
  sbp->replyref (res);
}

void
dsdc_slave_t::handle_put (svccb *sbp)
{
  dsdc_put_arg_t *a = sbp->Xtmpl getarg<dsdc_put_arg_t> ();
  bool rc = lru_insert (a->key, a->obj);
  dsdc_res_t res = rc ? DSDC_REPLACED : DSDC_INSERTED;
  if (show_debug (1)) {
    warn ("insert issued (rc=%d): %s\n", res, key_to_str (a->key).cstr ());
  }
  sbp->replyref (res);
}

dsdc_obj_t *
dsdc_slave_t::lru_lookup (const dsdc_key_t &k)
{
  dsdc_cache_obj_t *o = _objs[k];
  if (o) {
    _lru.remove (o);
    _lru.insert_tail (o);
    return &o->_obj;
  }
  return NULL;
}

size_t
dsdc_slave_t::lru_remove_obj (dsdc_cache_obj_t *o, bool del)
{
  if (!o) {
    o = _lru.first;

    // it could be that what's inserted is bigger than the whole cache
    // size allotment.  in this case, we'll bend the rules a little
    // bit and allow only it to be inserted.
    if (!o)
      return 0;

    if (show_debug (2)) 
      warn ("LRU Delete triggered: %s\n", key_to_str (o->_key).cstr ());
  }
  
  assert (o);
  
  _lru.remove (o);
  _objs.remove (o);
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
    lru_remove_obj (o, true);
    ret = true;
  }
  return ret;
}

bool
dsdc_slave_t::lru_insert (const dsdc_key_t &k, const dsdc_obj_t &o)
{
  bool ret = false;
  dsdc_cache_obj_t *co;

  if ((co = _objs[k])) {
    co->reset ();
    lru_remove_obj (co, false);
    ret = true;
  } else {    
    co = New dsdc_cache_obj_t ();
  }

  co->set (k, o);

  size_t sz = co->size ();
  
  // stop looping when either (1) we've made enough room or
  // (2) there is nothing more to delete!
  while (_lrusz && sz + _lrusz > _maxsz) {
    lru_remove_obj (NULL, true);
  }

  _lru.insert_head (co);
  _objs.insert (co);
  _lrusz += co->size ();

  return ret;
}

void
dsdc_slave_t::add_master (const str &h, int p)
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
dsdc_slave_t::init ()
{
  if (!get_port ())
    return false;
  genkeys ();
  for (dsdcs_master_t *m = _masters.first; m ; m = _masters.next (m)) {
    m->connect ();
  }
  schedule_refresh ();
  return true;
}

bool
dsdc_slave_t::get_port ()
{
  _lfd = -1;
  int p_begin = _port;
  u_int i;
  for (i = 0; i < dsdcs_port_attempts && i < USHRT_MAX && _lfd < 0; i++) {
    _lfd = inetsocket (SOCK_STREAM, _port);
    if (_lfd < 0) {
      warn ("port=%d attempt failed: %m\n", _port);
      _port++;
    }
  }
  if (_lfd > 0) {
    if (show_debug (1)) 
    close_on_exec (_lfd);
    listen (_lfd, 256);
    fdcb (_lfd, selread, wrap (this, &dsdc_slave_t::new_connection));
    return true;
  } else {
    warn << "tried ports from " << p_begin << " to " << p_begin + i 
	 << "; all failed\n";
    return false;
  }
}

str
dsdc_slave_t::startup_msg () const
{
  strbuf b ("listening on %s:%d", dsdc_hostname.cstr (), _port);
  if (show_debug (2)) 
    b.fmt ("; nnodes=%d, maxsz=0x%x", 
	    _n_nodes, _maxsz);
  return b;
}


dsdc_slave_t::dsdc_slave_t (u_int n, u_int s, int p)
  : dsdc_app_t (), dsdc_system_state_cache_t (),
    _lrusz (0),
    _n_nodes (n ? n : dsdc_slave_nnodes),
    _maxsz (s ? s : dsdc_slave_maxsz),
    _primary (true),
    _port (p),
    _lfd (-1)
{}

void 
dsdc_slave_t::get_xdr_repr (dsdcx_slave_t *x)
{
  x->keys = _keys;
  x->port = _port;
  x->hostname = dsdc_hostname;
}

void
dsdc_slave_t::handle_custom (svccb *sbp)
{
  sbp->reject (PROC_UNAVAIL);
}

