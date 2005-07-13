
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

typedef callback<void, ptr<dsdc_get_res_t> >::ref dsdc_lookup_res_cb_t;

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
  const str &hostname () const { return _hostname; }

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

//
// dsdc smart client: 
//   while "dumb" clients go through the master for lookups and inserts,
//   smart clients maintain a version of the ring and can therefore 
//   route their own lookups, saving latency and load on the master
//
class dsdc_smartcli_t : public dsdc_system_state_cache_t {
public:
  dsdc_smartcli_t () : _curr_master (NULL) {}

  void init (cbb::ptr cb);

  bool add_master (const str &hostname, int port);

  void put (ptr<dsdc_put_arg_t> arg, cbi::ptr cb = NULL, bool safe = false);
  void get (ptr<dsdc_key_t> key, dsdc_lookup_res_cb_t cb, bool safe = false);
  void remove (ptr<dsdc_key_t> key, cbi::ptr cb = NULL, bool safe = false);
  
  // fulfill the virtual interface of dsdc_system_cache_t
  ptr<aclnt> get_primary ();
  aclnt_wrap_t *new_wrap (const str &h, int p);

  void pre_construct ();
  void post_construct ();


  void get_cb_1 (ptr<dsdc_key_t> k, dsdc_lookup_res_cb_t cb, 
		    ptr<aclnt> cli);
  void get_cb_2 (ptr<dsdc_key_t> k, dsdc_lookup_res_cb_t cb,
		 ptr<dsdc_get_res_t> res, clnt_stat err);
protected:

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
private:
  dsdci_master_t *_curr_master;

  tailq<dsdci_master_t, &dsdci_master_t::_lnk> _masters;
  fhash<str, dsdci_master_t, &dsdci_master_t::_hlnk> _masters_hash;

  list<dsdci_slave_t, &dsdci_slave_t::_lnk> _slaves;
  fhash<str, dsdci_slave_t, &dsdci_slave_t::_hlnk> _slaves_hash;
  bhash<str> _slaves_hash_tmp;
};


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



#endif /* _DSDC_SMARTCLI_H */


