
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

typedef callback<void, ptr<dsdc_lookup_res_t> >::ref dsdc_lookup_res_cb_t;

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
  const str &key () const { return _key; }
  void connect (cbb cb);
  void connect_cb (cbb cb, int f);

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

  bool add_master (const str &hostname, int port);

  void insert (ptr<dsdc_insert_arg_t> arg, bool safe, cbi::ptr cb);
  void lookup (ptr<dsdc_key_t> key, dsdc_lookup_res_cb_t cb);
  void remove (ptr<dsdc_key_t> key, cbi::ptr cb);
  
  // fulfill the virtual interface of dsdc_system_cache_t
  ptr<aclnt> get_primary ();
  aclnt_wrap_t *new_wrap (const str &h, int p);

  void pre_construct ();
  void post_construct ();


  void lookup_cb_1 (ptr<dsdc_key_t> k, dsdc_lookup_res_cb_t cb, 
		    ptr<aclnt> cli);
  void lookup_cb_2 (ptr<dsdc_key_t> k, dsdc_lookup_res_cb_t cb,
		    ptr<dsdc_lookup_res_t> res, clnt_stat err);

private:
  dsdci_master_t *_curr_master;

  tailq<dsdci_master_t, &dsdci_master_t::_lnk> _masters;
  fhash<str, dsdci_master_t, &dsdci_master_t::_hlnk> _masters_hash;

  list<dsdci_slave_t, &dsdci_slave_t::_lnk> _slaves;
  fhash<str, dsdci_slave_t, &dsdci_slave_t::_hlnk> _slaves_hash;
  bhash<str> _slaves_hash_tmp;
};


#endif /* _DSDC_SMARTCLI_H */


