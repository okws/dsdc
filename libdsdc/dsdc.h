
// -*-c++-*-
/* $Id$ */

#ifndef _DSDC_SMARTCLI_H
#define _DSDC_SMARTCLI_H

#include "dsdc_prot.h"
#include "dsdc.h"
#include "dsdc_ring.h"
#include "arpc.h"
#include "dsdc_state.h"
#include "qhash.h"

//
// dsdci_srv_t
// 
//  dsdci = dsdc intelligent, which is the prefix for smart clients
//
//  this class is a base class for any hostname/port pair that
//  we will maintain for the smart client to connect to
//  
class dsdci_srv_t : public aclnt_wrap_t {
public:
  dsdci_srv_t (const str &h, int p) ;
  virtual ~dsdci_srv_t () { *_destroyed = true; }

  const str &key () const { return _key; }
  void connect (cbb cb);
  void connect_cb (cbb cb, int f);

  void hit_eof (ptr<bool> df); // call this when there is an EOF

  // for aclnt_wrap_t virtual interface
  ptr<aclnt> get_aclnt () { return _cli; }
  void get_aclnt (aclnt_cb_t cb);
  void get_aclnt_cb (aclnt_cb_t cb, bool b);
  bool is_dead () ;

  // a remote peer is identified by a <hostname>:<port>
  const str &remote_peer_id () const { return _key; }

  const str _key;
private:
  const str _hostname;
  const int _port;
  int _fd;

  ptr<axprt> _x;
  ptr<aclnt> _cli;
  ptr<bool> _destroyed;
};


//
// dsci_master_t
//   
//   maintains a persistent connection to a master, periodically downloading
//   the ring so that lookups and inserts are routed appropriately
//
class dsdci_master_t : public dsdci_srv_t {
public:
  dsdci_master_t (const str &h, int p) : dsdci_srv_t (h,p) {}

  tailq_entry<dsdci_master_t> _lnk;
  ihash_entry<dsdci_master_t> _hlnk;
};

//
// dsdci_slave_t
//
//   keep persistent connection to slaves that we use so we don't need
//   to reconnect every time.
//
class dsdci_slave_t : public dsdci_srv_t {
public:
  dsdci_slave_t (const str &h, int p) : dsdci_srv_t (h, p) {}
  list_entry<dsdci_slave_t> _lnk;
  ihash_entry<dsdci_slave_t> _hlnk;
};

template<> struct keyfn<dsdci_master_t, str> {
  keyfn () {}
  const str &operator () (dsdci_master_t *i) const { return i->key (); }
};

template<> struct keyfn<dsdci_slave_t, str> {
  keyfn () {}
  const str &operator () (dsdci_slave_t *i) const { return i->key (); }
};

// callback type for returning from get() calls below
typedef callback<void, ptr<dsdc_get_res_t> >::ref dsdc_get_res_cb_t;
typedef callback<void, ptr<dsdc_mget_res_t> >::ref dsdc_mget_res_cb_t;

class dsdc_smartcli_t;


//
// a convenience class so that we only need to specify the
// templated parameters once.
//
template<class K, class V>
class dsdc_iface_t {
public:
  dsdc_iface_t (dsdc_smartcli_t *c) : _cli (c) {}

  void get (const K &k, 
	    typename callback<void, dsdc_res_t, ptr<V> >::ref cb,
	    bool safe = false );
  void put (const K &k, const V &obj, cbi::ptr cb = NULL,
	    bool safe = false);
  void remove (const K &k, cbi::ptr cb = NULL, bool safe = false);

private:
  dsdc_smartcli_t *_cli;

};

//
// dsdc smart client: 
//
//   while "dumb" clients go through the master for lookups and inserts,
//   smart clients maintain a version of the ring and can therefore 
//   route their own lookups, saving latency and load on the master
//
//   the API to this class is with the 6 or so public functions below.
//
class dsdc_smartcli_t : public dsdc_system_state_cache_t {
public:
  dsdc_smartcli_t () : _curr_master (NULL) {}

  // adds a master from a string only, in the form
  // <hostname>:<port>
  bool add_master (const str &m);

  // add a new master server to the smart client.
  // returns true if the insert succeeded (if the master is not
  // a duplicate) and false otherwise.
  bool add_master (const str &hostname, int port);

  // initialize the smart client; get a callback with a "true" result
  // as soon as one master connection succeeds, or with a "false" result
  // after all connections fail.
  void init (cbb::ptr cb);

  //
  // put/get/remove objects into the ring. 
  //
  //   for put/remove, the callback is optional, and give it NULL if
  //   you don't care about the result. 
  // 
  //   specify the "safe" flag for extra safety.  that is, if you
  //   want to push/pull data through the masters, with some added
  //   assurence of consistency.  for most operations, do not supply
  //   the safe flag, and rely on the smart client's knowledge
  //   of the cache state.
  //
  void put (ptr<dsdc_put_arg_t> arg, cbi::ptr cb = NULL, bool safe = false);
  void get (ptr<dsdc_key_t> key, dsdc_get_res_cb_t cb, bool safe = false);
  void remove (ptr<dsdc_key_t> key, cbi::ptr cb = NULL, bool safe = false);
  void mget (ptr<vec<dsdc_key_t> > keys, dsdc_mget_res_cb_t cb);

  // slightly more automated versions of the above; call xdr2str/str2xdr
  // automatically, and therefore less code for the app designer
  template<class T> void put2 (const dsdc_key_t &k, const T &obj, 
			       cbi::ptr cb = NULL, bool safe = false);
  template<class T> 
  void get2 (ptr<dsdc_key_t> k, 
	     typename callback<void, dsdc_res_t, ptr<T> >::ref cb,
	     bool safe = false);

  // even more convenient version of the above!
  template<class K, class V> void 
  put3 (const K &k, const V &obj, cbi::ptr cb = NULL, 
	bool safe = false);
  template<class K, class V> void 
  get3 (const K &k, typename callback<void, dsdc_res_t, ptr<V> >::ref cb,
	bool safe = false);
  template<class K> void
  remove3 (const K &k, cbi::ptr cb = NULL, bool safe = false);


  // an interface to wrap up the templated types in one place
  template<class K, class O> 
  ptr<dsdc_iface_t<K,O> >
  make_interface () { return New refcounted<dsdc_iface_t<K,O> > (this); }

protected:

  // fulfill the virtual interface of dsdc_system_cache_t
  ptr<aclnt> get_primary ();
  aclnt_wrap_t *new_wrap (const str &h, int p);

  void pre_construct ();
  void post_construct ();

  void get_cb_1 (ptr<dsdc_key_t> k, dsdc_get_res_cb_t cb, 
		 ptr<aclnt> cli);
  void get_cb_2 (ptr<dsdc_key_t> k, dsdc_get_res_cb_t cb,
		 ptr<dsdc_get_res_t> res, clnt_stat err);

  template<class T> void
  get2_cb_1 (typename callback<void, dsdc_res_t, ptr<T> >::ref cb,
	     ptr<dsdc_get_res_t> res);


  //---------------------------------------------------------------------
  // change cache code

  // cc_t - temporary object useful for changing the cache by
  // issuing updates or deletes. see the next 4 functions
  // for where it's used.  should not be used anywhere else
  template<class T>
  struct cc_t {
    cc_t () {}
    cc_t (const dsdc_key_t &k, ptr<T> a, int p, cbi::ptr c)
      : key (k), arg (a), proc (p), cb (c), res (New refcounted<int> ()) {}

    ~cc_t () { if (cb) (*cb) (*res); }

    void set_res (int i) { *res = i; }

    dsdc_key_t key;
    ptr<T> arg;
    int proc;
    cbi::ptr cb;
    ptr<aclnt> cli;
    ptr<int> res;
  };

  template<class T> void 
  change_cache (const dsdc_key_t &k, ptr<T> arg, int, cbi::ptr, bool);

  template<class T> void change_cache (ptr<cc_t<T> > cc, bool safe);
  template<class T> void change_cache_cb_2 (ptr<cc_t<T> > cc, clnt_stat err);
  template<class T> void change_cache_cb_1 (ptr<cc_t<T> > cc, ptr<aclnt> cli);

  //
  // end change cache code
  //---------------------------------------------------------------------

  //-----------------------------------------------------------------------
  // init code
  //   required semantics: first master wins, but if all masters
  //   fail, then we're required to say that
  //
  struct init_t {
    init_t (cbb c) : _cb (c), _success (false) {}
    ~init_t () { if (!_success) (*_cb) (false); }

    // assure that _cb can only be triggered once
    void success () 
    { 
      if (!_success) {
	_success = true; 
	(*_cb) (true); 
      }
    }
    cbb _cb;
    bool _success;
  };
  void init_cb (ptr<init_t> i, dsdci_master_t *m, bool b);
  //
  // end init code
  //-----------------------------------------------------------------------

protected:
  dsdci_master_t *_curr_master;

  tailq<dsdci_master_t, &dsdci_master_t::_lnk> _masters;
  fhash<str, dsdci_master_t, &dsdci_master_t::_hlnk> _masters_hash;

  list<dsdci_slave_t, &dsdci_slave_t::_lnk> _slaves;
  fhash<str, dsdci_slave_t, &dsdci_slave_t::_hlnk> _slaves_hash;
  bhash<str> _slaves_hash_tmp;
};

//-----------------------------------------------------------------------
// Shortcut Functions!
// 
//  functions to simplify getting and putting data, hopefully.
//

// give an XDR object, find its key
template<class T> ptr<dsdc_key_t> 
mkkey_ptr (const T &obj)
{
  ptr<dsdc_key_t> ret = New refcounted<dsdc_key_t> ();
  mkkey (ret, obj);
  return ret;
}

template<class T> dsdc_key_t
mkkey (const T &obj)
{
  dsdc_key_t ret;
  mkkey (&ret, obj);
  return ret;
}

template<class T> void
mkkey (dsdc_key_t *k, const T &obj)
{
  sha1_hashxdr (k->base (), obj);
}

//
//
//-----------------------------------------------------------------------

//-----------------------------------------------------------------------
// dsdc_smartcli_t templated function implementation
// 
template<class T> void 
dsdc_smartcli_t::change_cache (const dsdc_key_t &k, ptr<T> arg, 
			       int proc, cbi::ptr cb, bool safe)
{
  change_cache<T> (New refcounted<cc_t<T> > (k, arg, proc, cb), safe);
}

template<class T> void
dsdc_smartcli_t::change_cache_cb_2 (ptr<cc_t<T> > cc, clnt_stat err)
{
  if (err) {
    if (show_debug (1)) {
      warn << "RPC error in proc=" << cc->proc << ": " << err << "\n";
    }
    cc->set_res (DSDC_RPC_ERROR);
  }
}

template<class T> void
dsdc_smartcli_t::change_cache_cb_1 (ptr<cc_t<T> > cc, ptr<aclnt> cli)
{
  if (!cli) {
    cc->set_res (DSDC_NONODE);
    return;
  }

  cli->call (cc->proc, cc->arg, cc->res,
	     wrap (this, &dsdc_smartcli_t::change_cache_cb_2<T>, cc));
}

template<class T> void
dsdc_smartcli_t::change_cache (ptr<cc_t<T> > cc, bool safe)
{
  if (safe) {
    change_cache_cb_1 (cc, get_primary ());
  } else {

    dsdc_ring_node_t *n = _hash_ring.successor (cc->key);
    if (!n) {
      cc->set_res (DSDC_NONODE);
      return;
    }
    n->get_aclnt_wrap ()
      ->get_aclnt (wrap (this, &dsdc_smartcli_t::change_cache_cb_1<T>, cc));
  }
}

//
//
//-----------------------------------------------------------------------

//
//

//-----------------------------------------------------------------------
// lazy man's version of the standard put/get interface, for simplifying
// use

template<class T> void
dsdc_smartcli_t::get2_cb_1 (typename callback<void, dsdc_res_t, 
			    ptr<T> >::ref cb,
			    ptr<dsdc_get_res_t> res)
{
  ptr<T> obj;
  if (res->status == DSDC_OK) {
    obj = New refcounted<T> ();
    bytes2xdr (*obj, *res->obj);
  }
  (*cb) (res->status, obj);
}

template<class T> void
dsdc_smartcli_t::get2 (ptr<dsdc_key_t> k, 
		       typename callback<void, dsdc_res_t, ptr<T> >::ref cb, 
		       bool safe)
{
  get (k, wrap (this, &dsdc_smartcli_t::get2_cb_1<T>, cb), safe);
}

template<class T> void
dsdc_smartcli_t::put2 (const dsdc_key_t &k, const T &obj,
		      cbi::ptr cb, bool safe)
{
  ptr<dsdc_put_arg_t> arg = New refcounted<dsdc_put_arg_t> ();
  arg->key = k;
  xdr2bytes (arg->obj, obj);
  put (arg, cb, false);
}

//
//-----------------------------------------------------------------------

//-----------------------------------------------------------------------
// even lazier!
//
template<class K, class V> void 
dsdc_smartcli_t::get3 (const K &k, 
		       typename callback<void, dsdc_res_t, ptr<V> >::ref cb,
		       bool safe)
{
  get2<V> (mkkey_ptr (k), cb, safe);
}
  
template<class K, class V> void 
dsdc_smartcli_t::put3 (const K &k, const V &obj, cbi::ptr cb, bool safe)
{
  put2 (mkkey (k), obj, cb, safe);
}

template<class K> void
dsdc_smartcli_t::remove3 (const K &k, cbi::ptr cb, bool safe)
{
  remove (mkkey_ptr (k), cb, safe);
}


template<class K, class V> void 
dsdc_iface_t<K,V>::get (const K &k, 
			typename callback<void, dsdc_res_t, ptr<V> >::ref cb,
			bool safe)
{ return _cli->template get3<K,V> (k, cb, safe); }

template<class K, class V> void 
dsdc_iface_t<K,V>::put (const K &k, const V &obj, cbi::ptr cb, bool safe)
{ return _cli->put3 (k, obj, cb, safe); }

template<class K, class V> void 
dsdc_iface_t<K,V>::remove (const K &k, cbi::ptr cb, bool safe)
{ return _cli->remove3 (k, cb, safe); }

//
//-----------------------------------------------------------------------



#endif /* _DSDC_SMARTCLI_H */


