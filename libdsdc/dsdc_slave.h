// -*-c++-*-
/* $Id$ */

#ifndef _DSDC_SLAVE_H
#define _DSDC_SLAVE_H

#include "dsdc_prot.h"
#include "dsdc_ring.h"
#include "dsdc_state.h"
#include "dsdc_const.h"
#include "dsdc_util.h"
#include "dsdc_lock.h"
#include "ihash.h"
#include "list.h"
#include "async.h"
#include "arpc.h"
#include "qhash.h"

struct dsdc_cache_obj_t {
  dsdc_cache_obj_t () : _timein (timenow) {}
  void reset () { _timein = timenow; }
  void set (const dsdc_key_t &k, const dsdc_obj_t &o);
  dsdc_cache_obj_t (const dsdc_key_t &k, const dsdc_obj_t &o);
  dsdc_key_t _key;
  dsdc_obj_t _obj;
  time_t _timein;
  size_t size () const { return _key.size () + _obj.size () + sizeof (*this); }
  ihash_entry<dsdc_cache_obj_t> _hlnk;
  tailq_entry<dsdc_cache_obj_t> _qlnk;
};

typedef enum { MASTER_STATUS_OK = 0,
	       MASTER_STATUS_CONNECTING = 1,
	       MASTER_STATUS_UP = 2,
	       MASTER_STATUS_DOWN = 3 } dsdcs_master_status_t;


class dsdc_slave_t;
class dsdc_slave_app_t;

class dsdcs_master_t {
public:
  dsdcs_master_t (dsdc_slave_app_t *s, const str &h, int p, bool pr) 
    : _slave (s), _status (MASTER_STATUS_DOWN), _hostname (h), 
      _port (p), _fd (-1), _primary (pr) {}

  void connect ();
  void dispatch (svccb *b);
  ptr<aclnt> cli () { return _cli; }
  dsdcs_master_status_t status () const { return _status; }
  
  list_entry<dsdcs_master_t> _lnk;

private:

  void connect_cb (int f);
  void master_warn (const str &m);
  void went_down (const str &w);
  void schedule_retry ();
  void heartbeat ();
  void schedule_heartbeat ();
  void do_register ();
  void do_register_cb (ptr<int> res, clnt_stat err);
  void retry ();
  void ready_to_serve ();

  dsdc_slave_app_t *_slave;
  dsdcs_master_status_t _status;

  const str _hostname;
  const int _port;

  int _fd;

  ptr<aclnt> _cli;
  ptr<axprt> _x;
  ptr<asrv> _srv;
  bool _primary;

};

// service p2p requests
class dsdcs_p2p_cli_t {
public:
  dsdcs_p2p_cli_t (dsdc_slave_app_t *p, int f, const str &h) 
    : _parent (p), _fd (f), _hn (h)
  {
    tcp_nodelay (_fd);
    _x = axprt_stream::alloc (_fd, dsdc_packet_sz);
    _asrv = asrv::alloc (_x, dsdc_prog_1,
			 wrap (this, &dsdcs_p2p_cli_t::dispatch));
  }
  void dispatch (svccb *sbp);
private:
  dsdc_slave_app_t *const _parent;
  const int _fd;
  ptr<axprt_stream> _x;
  ptr<asrv> _asrv;
  const str _hn;
};

#define SLAVE_DETERMINISTIC_SEEDS    (1 << 0)
#define SLAVE_NO_CLEAN (1 << 1)

// There are two possible slave apps as of now:
//
//   - Slave data store (dsdc_slave_t)
//   - Slave lock server (dsdcs_lockserver_t)
//
// The naming is unforuntate but there due to historical limitations.
class dsdc_slave_app_t : public dsdc_app_t {
public:
  dsdc_slave_app_t (int p, int opts);
  virtual ~dsdc_slave_app_t () {}
  void add_master (const str &h, int p);
  virtual void dispatch (svccb *sbp) = 0;
  virtual bool init ();
  virtual void get_xdr_repr (dsdcx_slave_t *x) ;
  virtual bool is_lock_server () const { return false; }

  str startup_msg () const ;
  virtual void startup_msg_v (strbuf *b) const {}
protected:
  bool get_port ();
  void new_connection ();
  /**
   * return an aclnt for the master that's currently serving as the
   * master primary.
   */
  ptr<aclnt> get_primary ();

  list<dsdcs_master_t, &dsdcs_master_t::_lnk> _masters;

  bool _primary; // a flag that's used to add the primary master only once
  int _port;     // listen for p2p communication
  int _lfd;
  
  int _opts;     // options for configuring this slave
};

class dsdcs_lockserver_t : public dsdc_slave_app_t, 
			   public dsdcl_mgr_t {
public:
  dsdcs_lockserver_t (int port, int o = 0) : 
    dsdc_slave_app_t (port, o) {}
  virtual ~dsdcs_lockserver_t () {}
  void dispatch (svccb *sbp);
  void get_xdr_repr (dsdcx_slave_t *x) ;
  bool is_lock_server () const { return true; }
  str progname_xtra () const { return "_nlm"; }
};

class dsdc_slave_t : public dsdc_slave_app_t ,
		     public dsdc_system_state_cache_t {
public:
  dsdc_slave_t (u_int nnodes = 0, u_int maxsz = 0, 
		int port = dsdc_slave_port, int opts = 0);
  virtual ~dsdc_slave_t () {}

  void startup_msg_v (strbuf *b) const;
  bool init ();
  const dsdc_keyset_t *get_keys () const { return &_keys; }
  void get_keys (dsdc_keyset_t *k) const { *k = _keys; }
  void get_xdr_repr (dsdcx_slave_t *x) ;

  void dispatch (svccb *sbp);
  void handle_get (svccb *sbp);
  void handle_mget (svccb *sbp);
  void handle_put (svccb *sbp);
  void handle_remove (svccb *sbp);

        // Match function addition.
  void handle_compute_matches (svccb *sbp);

  str progname_xtra () const { return "_slave"; }

  // implement virtual functions from the 
  // dsdc_system_state_cache class
  aclnt_wrap_t *new_wrap (const str &h, int p) { return NULL; }
  aclnt_wrap_t *new_lockserver_wrap (const str &h, int p) { return NULL; }
  ptr<aclnt> get_primary () { return dsdc_slave_app_t::get_primary (); }
protected:

  void genkeys ();
  dsdc_obj_t * lru_lookup (const dsdc_key_t &k, const int expire=INT_MAX);
  size_t lru_remove_obj (dsdc_cache_obj_t *o, bool del);
  bool lru_remove (const dsdc_key_t &k);
  bool lru_insert (const dsdc_key_t &k, const dsdc_obj_t &o);
  size_t _lrusz;

  void clean_cache ();

  dsdc_keyset_t _keys;
  const u_int _n_nodes;
  const size_t _maxsz;


  ihash<dsdc_key_t, dsdc_cache_obj_t, &dsdc_cache_obj_t::_key,
    &dsdc_cache_obj_t::_hlnk, 
    dsdck_hashfn_t, dsdck_equals_t> _objs;

  bhash<dsdc_key_t, dsdck_hashfn_t, dsdck_equals_t> _khash;

  tailq<dsdc_cache_obj_t, &dsdc_cache_obj_t::_qlnk> _lru;

private:
#ifndef DSDC_NO_CUPID
  void fill_datum(
	u_int64_t userid,
	matchd_qanswer_rows_t *user_questions,
	matchd_frontd_match_datum_t &datum);
#endif

};

#endif /* _DSDC_SLAVE_H */
