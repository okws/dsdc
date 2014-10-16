// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-
//-----------------------------------------------------------------------
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
#include "dsdc_stats.h"
#include "litetime.h"

struct dsdc_cache_obj_t {
    dsdc_cache_obj_t () : _timein (sfs_get_timenow ()), _annotation (NULL),
            _n_gets (0), _n_gets_in_epoch (0) {}
    void reset () { _timein = sfs_get_timenow (); }
    void set (const dsdc_key_t &k, const dsdc_obj_t &o,
              dsdc::annotation::base_t *a = NULL);
    dsdc_cache_obj_t (const dsdc_key_t &k, const dsdc_obj_t &o);
    time_t lifetime () const { return sfs_get_timenow ()- _timein; }
    void inc_gets () { _n_gets ++; _n_gets_in_epoch ++; }
    const dsdc::annotation::base_t *annotation () const { return _annotation; }
    dsdc::annotation::base_t *annotation () { return _annotation; }
    size_t size () const
    { return _key.size () + _obj.size () + sizeof (*this); }
    void collect_statistics (bool del = true,
                             dsdc::action_code_t t = dsdc::AC_NONE);
    bool match_checksum (const dsdc_cksum_t &cksum) const;

    dsdc_key_t _key;
    dsdc_obj_t _obj;
    time_t _timein;
    dsdc::annotation::base_t *_annotation;
    u_int _n_gets, _n_gets_in_epoch;

    ihash_entry<dsdc_cache_obj_t> _hlnk;
    tailq_entry<dsdc_cache_obj_t> _qlnk;
};

typedef enum { MASTER_STATUS_OK = 0,
               MASTER_STATUS_CONNECTING = 1,
               MASTER_STATUS_UP = 2,
               MASTER_STATUS_DOWN = 3
             } dsdcs_master_status_t;


class dsdc_slave_t;
class dsdc_slave_app_t;

class dsdcs_master_t {
public:
    dsdcs_master_t (dsdc_slave_app_t *s, const str &h, int p, bool pr)
            : _slave (s), _status (MASTER_STATUS_DOWN), _hostname (h),
            _port (p), _fd (-1), _primary (pr) {}

    void connect ();
    void dispatch (svccb *b);
    ptr<connection_t> cli () { return _cli; }
    dsdcs_master_status_t status () const { return _status; }

    list_entry<dsdcs_master_t> _lnk;

private:

    void connect_cb (int f);
    void master_warn (const str &m);
    void went_down (const str &w, u_int lev = 0);
    void schedule_retry ();
    void heartbeat_T (CLOSURE);
    void heartbeat () { heartbeat_T (); }
    void schedule_heartbeat ();
    void do_register (CLOSURE);
    void do_register_cb (ptr<int> res, clnt_stat err);
    void retry ();
    void ready_to_serve ();

    dsdc_slave_app_t *_slave;
    dsdcs_master_status_t _status;

    const str _hostname;
    const int _port;

    int _fd;

    ptr<connection_t> _cli;
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
    void set_stats_mode (bool b);

protected:

    bool get_port ();
    void new_connection ();
    /**
     * return an aclnt for the master that's currently serving as the
     * master primary.
     */
    ptr<connection_t> get_primary ();

    list<dsdcs_master_t, &dsdcs_master_t::_lnk> _masters;

    bool _primary; // a flag that's used to add the primary master only once
    int _port;     // listen for p2p communication
    int _lfd;

    int _opts;     // options for configuring this slave
    bool _stats_mode; // on if we should be collecting stats
    int  _stats_mode2;  // > 0 if stats2 is running currently
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

class dsdc_lru_t {
public:
    dsdc_lru_t () : _slow_cursor (NULL) {}
    
    // For a "slow walk" over the LRU, which can be interrupted by 
    // twaits{}'s, use this slow_next() feature.
    void slow_reset ();
    dsdc_cache_obj_t *slow_next ();

    dsdc_cache_obj_t *first ();
    dsdc_cache_obj_t *next (dsdc_cache_obj_t *o);

    void remove (dsdc_cache_obj_t *o);
    void insert_tail (dsdc_cache_obj_t *o);
private:
    dsdc_cache_obj_t *_slow_cursor;
    tailq<dsdc_cache_obj_t, &dsdc_cache_obj_t::_qlnk> _lru;
};

class dsdc_slave_t : public dsdc_slave_app_t ,
            public dsdc_system_state_cache_t {
public:
    dsdc_slave_t (u_int nnodes = 0, size_t maxsz = 0,
                  int port = dsdc_slave_port, int opts = 0);
    virtual ~dsdc_slave_t () {}

    void startup_msg_v (strbuf *b) const;
    bool init ();
    const dsdc_keyset_t *get_keys () const { return &_keys; }
    void get_keys (dsdc_keyset_t *k) const { *k = _keys; }
    void get_xdr_repr (dsdcx_slave_t *x) ;
    bool clean_on_all_masters_dead () const { return false; }

    void dispatch (svccb *sbp);
    void handle_get (svccb *sbp);
    void handle_mget (svccb *sbp);
    void handle_put (svccb *sbp);
    void handle_put3 (svccb *sbp);
    void handle_put4 (svccb *sbp);
    void handle_remove (svccb *sbp);
    void handle_get_stats (svccb *sbp);
    void handle_set_stats_mode (svccb *sbp);

    // Match function addition.
    void handle_compute_matches (svccb *sbp);

    str progname_xtra () const { return "_slave"; }

    // implement virtual functions from the
    // dsdc_system_state_cache class
    ptr<connection_wrap_t> new_wrap (const str &h, int p) { return NULL; }
    ptr<connection_wrap_t> new_lockserver_wrap (const str &h, int p) { return NULL; }
    ptr<connection_t> get_primary () { return dsdc_slave_app_t::get_primary (); }
    void set_stats_mode2 (int i);
protected:
    void run_stats2_loop (CLOSURE);

    dsdc_res_t handle_put (const dsdc_key_t &k, const dsdc_obj_t &o,
                           dsdc::annotation::base_t *a = NULL,
                           const dsdc_cksum_t *cksum = NULL);
    void genkeys ();

    dsdc_obj_t * lru_lookup (const dsdc_key_t &k, const int expire=-1,
                             dsdc::annotation::base_t *a  = NULL,
                             bool* expired = NULL);

    size_t lru_remove_obj (dsdc_cache_obj_t *o, bool del,
                           dsdc::action_code_t t);
    bool lru_remove (const dsdc_key_t &k);
    dsdc_res_t lru_insert (const dsdc_key_t &k, const dsdc_obj_t &o,
                           dsdc::annotation::base_t *a = NULL,
                           const dsdc_cksum_t *cks = NULL);
    size_t _lrusz;

    void clean_cache () { clean_cache_T (); }

    dsdc_keyset_t _keys;
    const u_int _n_nodes;
    const size_t _maxsz;
    bool _cleaning;
    bool _dirty;


    ihash<dsdc_key_t, dsdc_cache_obj_t, &dsdc_cache_obj_t::_key,
    &dsdc_cache_obj_t::_hlnk,
    dsdck_hashfn_t, dsdck_equals_t> _objs;

    bhash<dsdc_key_t, dsdck_hashfn_t, dsdck_equals_t> _khash;

    dsdc_lru_t _lru;

private:
    void clean_cache_T (CLOSURE);

};

#endif /* _DSDC_SLAVE_H */
