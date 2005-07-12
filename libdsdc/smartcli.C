
#include "dsdc_smartcli.h"
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

  if (show_debug (1))
    warn << "EOF from remote peer: " << key () << "\n";

  _fd = -1;
  _cli = NULL;
  _x = NULL;
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
    return false;

  if (!_x || _x->ateof ()) {
    hit_eof (_destroyed);
    return false;
  }
  return true;
}

void
dsdc_smartcli_t::pre_construct ()
{
  _slaves_hash_tmp.clear ();
}

aclnt_wrap_t *
dsdc_smartcli_t::new_wrap (const str &h, int p)
{
  dsdci_slave_t *s = New dsdci_slave_t (h, p);
  dsdci_slave_t *ret = NULL;
  if ((ret = _slaves_hash[s->key ()])) {
    delete s;
  } else {
    _slaves_hash.insert (s);
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
  for (dsdci_slave_t *s = _slaves.first; s; s = _slaves.next (s)) {
    if (! _slaves_hash_tmp[s->key ()]) {
      if (show_debug (2)) {
	warn << "CLEAN: removing slave node: " << s->key () << "\n";
      }
      _slaves.remove (s);
      _slaves_hash.remove (s);
      delete s;
    }
  }
}

void
dsdc_smartcli_t::lookup (ptr<dsdc_key_t> k, dsdc_lookup_res_cb_t cb)
{
  dsdc_ring_node_t *n = _hash_ring.successor (*k);
  if (!n) {
    (*cb) (New refcounted<dsdc_lookup_res_t> (DSDC_NONODE));
    return;
  }
  n->get_aclnt_wrap ()
    ->get_aclnt (wrap (this, &dsdc_smartcli_t::lookup_cb_1, k, cb));
}


void
dsdc_smartcli_t::insert (ptr<dsdc_insert_arg_t> arg, bool safe, cbi::ptr cb)
{
  change_cache<dsdc_insert_arg_t> (arg->key, arg, int (DSDC_INSERT), cb, safe);
}

void
dsdc_smartcli_t::remove (ptr<dsdc_key_t> key, bool safe, cbi::ptr cb)
{
  change_cache<dsdc_key_t> (*key, key, int (DSDC_REMOVE), cb, safe);
}

void
dsdc_smartcli_t::lookup_cb_2 (ptr<dsdc_key_t> k, dsdc_lookup_res_cb_t cb,
			      ptr<dsdc_lookup_res_t> res, clnt_stat err)
{
  if (err) {
    if (show_debug (1)) {
      warn << "lookup failed with RPC error: " << err << "\n";
    }
    res->set_status (DSDC_RPC_ERROR);
    *res->err = err;
  }
  (*cb) (res);
}

void
dsdc_smartcli_t::lookup_cb_1 (ptr<dsdc_key_t> k, dsdc_lookup_res_cb_t cb,
			      ptr<aclnt> cli)
{
  if (!cli) {
    (*cb) (New refcounted<dsdc_lookup_res_t> (DSDC_DEAD));
    return;
  }
  ptr<dsdc_lookup_res_t> res = New refcounted<dsdc_lookup_res_t> ();
  cli->call (DSDC_LOOKUP, k, res,
	     wrap (this, &dsdc_smartcli_t::lookup_cb_2, k, cb, res));
}

void
dsdci_srv_t::connect_cb (cbb cb, int f)
{
  bool ret = true;
  if ((_fd = f) < 0) {
    if (show_debug (1)) {
      warn << "connection to slave failed: " << key () << "\n";
    }
    ret = false;
  } else {
    if (show_debug (3)) {
      warn << "connection to slave succeeded: " << key () << "\n";
    }
    assert ((_x = axprt_stream::alloc (_fd, dsdc_packet_sz)));
    _cli = aclnt::alloc (_x, dsdc_prog_1);
    _cli->seteofcb (wrap (this, &dsdci_srv_t::hit_eof, _destroyed));
  }
  (*cb) (true);
} 

void
dsdci_srv_t::connect (cbb cb)
{
  if (!is_dead ()) {
    (*cb) (true);
    return;
  }
  tcpconnect (_hostname, _port, wrap (this, &dsdci_srv_t::connect_cb, cb));
}

void
dsdci_srv_t::get_aclnt_cb (aclnt_cb_t cb, bool b)
{
  (*cb) (_cli);
}

void
dsdci_srv_t::get_aclnt (aclnt_cb_t cb)
{
  if (!is_dead () && _cli) {
    (*cb) (_cli);
    return;
  }
  connect (wrap (this, &dsdci_srv_t::get_aclnt_cb, cb));
}

void
dsdc_smartcli_t::init (cbb::ptr cb)
{
  (*cb) (false);

}

