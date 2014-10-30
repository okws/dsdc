// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-
/* $Id$ */

#ifndef _DSDC_MASTER_H
#define _DSDC_MASTER_H

#include "dsdc_prot.h"  // protocol file definitions
#include "dsdc_util.h"  // elements common to master and slave
#include "dsdc_const.h" // constants
#include "dsdc_ring.h"  // the consistent hash ring

#include "itree.h"
#include "ihash.h"
#include "async.h"
#include "arpc.h"
#include "tame.h"

//
// a glossary:
//
//   dsdc  - Dirt Simple Distributed Cache
//   dsdcm - A master process
//   dsdcs - A slave process
//   dsdck - a key
//   dsdcn - A node in the global consistent hash ring.
//


class dsdc_master_t;
class dsdcm_slave_base_t;

// one of these objects is allocated for each extern client served;
// i.e., there is one per incoming TCP connection. when the
// external client goes away, so, too, does this thing.
class dsdcm_client_t : public virtual refcount {
public:
    static ptr<dsdcm_client_t> alloc (dsdc_master_t *m, int _fd, const str &h);
    ~dsdcm_client_t () {}
    void release ();

    void dispatch (svccb *b);          // handle a request
    list_entry<dsdcm_client_t> _lnk;   // for insert into a list of clients

    dsdc_master_t *get_master () { return _master; }
    const str &remote_peer_id () const { return _hostname; }

    void unregister_slave () { _slave = NULL; }

protected:
    dsdcm_client_t (dsdc_master_t *m, int _fd, const str &h);
    void init ();
    void handle_heartbeat (svccb *b);
    void handle_register (svccb *b);
    void handle_register2 (svccb *b);

    // if this client has registered as a slave, then this pointer field
    // will be set.  we set up bidirectional pointers here.
    ptr<dsdcm_slave_base_t> _slave;

    dsdc_master_t *_master; // master objet
    int _fd;                // the client's fd
    ptr<axprt> _x;          // a wrapper around the fd for the client
    ptr<asrv> _asrv;        // async RPC server
    str _hostname;          // hostname / port of client
};

/**
 * a base class used by both dsdcm_slave_t (which stores data) and
 * also dsdcm_lock_server_t, which just handles locking.  Both types
 * of slaves start out as regular clients, but are promoted when a
 * a regsiter call is made.
 */
class dsdcm_slave_base_t : public connection_wrap_t {
public:
    dsdcm_slave_base_t (ptr<dsdcm_client_t> c, ptr<axprt> x);
    virtual ~dsdcm_slave_base_t () {}
    void release ();
    void init (const dsdcx_slave2_t &keys);
    void get_xdr_repr (dsdcx_slave2_t *o) { *o = _xdr_repr; }
    const str &remote_peer_id () const { return _client->remote_peer_id (); }
    ptr<connection_t> get_aclnt () { return _clnt_to_slave; }
    void handle_heartbeat () { _last_heartbeat = sfs_get_timenow (); }

    bool is_dead ();                    // if no heartbeat, assume dead

    // Instead of calling delete, call this guy...

    /**
     * insert all of this slave's node into the master hash ring.
     * data servers obviously need nodes so that data can be
     * routed toward them.  for now, locking is going to be centralized,
     * so there is no need for lock servers to have node; their insert
     * operations will be noops..
     */
    void insert_nodes ();
    virtual void insert_node (dsdc_master_t *m, dsdc_ring_node_t *n) = 0;

    /**
     * clean out all of this slave's nodes from the master's hash ring.
     * has polymorphic behavior based on whether the slave is a lock
     * server or a data server. remove_node() calls the virtual
     * remove_nodes ();
     */
    void remove_nodes ();
    virtual void remove_node (dsdc_master_t *m, dsdc_ring_node_t *n) = 0;


protected:
    dsdcx_slave2_t _xdr_repr;           // XDR representation of us
    ptr<dsdcm_client_t> _client;       // associated client object
    ptr<connection_t> _clnt_to_slave;         // RPC client for talking to slave
    vec<dsdc_ring_node_t *> _nodes;    // this slave's nodes in the ring
    time_t _last_heartbeat;            // last reported heartbeat
};

/**
 * corresponds to remote slave that will be doing data storing.
 */
class dsdcm_slave_t : public dsdcm_slave_base_t {
public:
    static ptr<dsdcm_slave_t> alloc (ptr<dsdcm_client_t> c, ptr<axprt> x);
    ~dsdcm_slave_t ();
    void remove_node (dsdc_master_t *m, dsdc_ring_node_t *n);
    void insert_node (dsdc_master_t *m, dsdc_ring_node_t *n);
    list_entry<dsdcm_slave_t> _lnk;
    ihash_entry<dsdcm_slave_t> _hlnk;

protected:
    dsdcm_slave_t (ptr<dsdcm_client_t> c, ptr<axprt> x,
                   str slave_type_str = "normal");
};

class dsdcm_redis_slave_t : public dsdcm_slave_t {
public:

    static ptr<dsdcm_redis_slave_t> alloc (ptr<dsdcm_client_t> c, 
                                           ptr<axprt> x);

    virtual bool is_dead() override;
    virtual ptr<connection_t> get_connection() override;
    virtual void get_connection(conn_cb_t cv, CLOSURE) override;

protected:
    dsdcm_redis_slave_t (ptr<dsdcm_client_t> c, ptr<axprt> x) :
        dsdcm_slave_t(c,x,"redis") { }

    ptr<redis_connection_t> m_redis = nullptr;
    bool m_force_dead = false;
};

template<> struct keyfn<dsdcm_slave_t, str>
{
    keyfn () {}
    const str & operator () (dsdcm_slave_t *s) const
    { return s->remote_peer_id (); }
};

/**
 * correspond to remote slave that will be a lock server.
 */
class dsdcm_lock_server_t : public dsdcm_slave_base_t {
public:
    static ptr<dsdcm_lock_server_t> alloc (ptr<dsdcm_client_t> c, ptr<axprt> x);
    ~dsdcm_lock_server_t ();
    void remove_node (dsdc_master_t *m, dsdc_ring_node_t *n);
    void insert_node (dsdc_master_t *m, dsdc_ring_node_t *n);
    tailq_entry<dsdcm_lock_server_t> _lnk;
protected:
    dsdcm_lock_server_t (ptr<dsdcm_client_t> c, ptr<axprt> x);
};

//
// a class representing all of the state that a master nodes maintains.
// in particular, it knows about all slave nodes, and also, about all
// which keys they represent.  it does not know about other master
// nodes.
//
class dsdc_master_t : public dsdc_app_t {
public:
    dsdc_master_t (int p = -1) :
            _port (p > 0 ? p : dsdc_port), _lfd (-1), _n_slaves (0) {}
    virtual ~dsdc_master_t () {}

    bool init ();                      // launch this master
    void new_connection ();            // a new connection on the listen port

    void insert_node (dsdc_ring_node_t *node)
    { _hash_ring.insert (node); }
    void remove_node (dsdc_ring_node_t *node)
    { _hash_ring.remove (node); }

    void insert_client (dsdcm_client_t *cli)
    { _clients.insert_head (cli); }
    void remove_client (dsdcm_client_t *cli)
    { _clients.remove (cli); }

    void insert_slave (dsdcm_slave_t *sl);
    void remove_slave (dsdcm_slave_t *sl);

    void insert_lock_server (dsdcm_lock_server_t *ls);
    void remove_lock_server (dsdcm_lock_server_t *ls);
    void insert_lock_node (dsdc_ring_node_t *node) {}
    void remove_lock_node (dsdc_ring_node_t *node) {}

    // given a key, look in the consistent hash ring for a corresponding
    // node, and then get the ptr<aclnt> that corresponds to the remote
    // host
    void get_connection (const dsdc_key_t &k, ptr<connection_t> *cli,
                         event<dsdc_res_t>::ref ev, CLOSURE);

    void handle_get (svccb *b, CLOSURE);
    void handle_remove (svccb *b, CLOSURE);
    void handle_put (svccb *b, CLOSURE);
    void handle_getstate (svccb *b);
    void handle_getstate2 (svccb *b);
    void handle_lock_release (svccb *b);
    void handle_lock_acquire (svccb *b);
    void handle_get_stats (svccb *b, CLOSURE);

    void broadcast_newnode (const dsdcx_slave_t &x, dsdcm_slave_t *skip,
                            CLOSURE);

    // manage the system state
    void reset_system_state ();
    void compute_system_state ();

    dsdcm_lock_server_t *lock_server () { return _lock_servers.first; }

    void watchdog_timer_loop (CLOSURE);

    str startup_msg () const
    {
        return strbuf ("master listening on %s:%d", dsdc_hostname.cstr (), _port);
    }
    str progname_xtra () const { return "_master"; }

    void downgrade_system_state(dsdcx_state_t& dstate,
                                const dsdcx_state2_t& ustate);
    void downgrade_slave(dsdcx_slave_t& dslave,
                         const dsdcx_slave2_t& ustate);
    void upgrade_slave(dsdcx_slave2_t& uslave,
                       const dsdcx_slave_t& dslave);

protected:
    void check_all_slaves ();
    void get_stats (dsdc_slave_statistic_t *out,
                    const dsdc_get_stats_single_arg_t *arg,
                    dsdcm_slave_t *sl, cbv cb, CLOSURE);

private:

    void broadcast_deletes (const dsdc_key_t &k, dsdcm_slave_t *skip);

    int _port;                         // the port it should listen on
    int _lfd;                          // listen file descriptor
    ptr<asrv> _srv;                    // for serving clients + slaves

    // keep track of all active clients (including slaves)
    list<dsdcm_client_t, &dsdcm_client_t::_lnk> _clients;

    // keep track of all of the slave pointers
    list<dsdcm_slave_t, &dsdcm_slave_t::_lnk> _slaves;
    fhash<str, dsdcm_slave_t, &dsdcm_slave_t::_hlnk> _slave_hash;
    int _n_slaves;

    // the itree containing all of the nodes in the consistent hash ring
    // for all of the slaves.  note that every slave in the ring can
    // hold many nodes in the ring; it's up to each slave.  the more
    // nodes that the slave has, the more load it will bear.
    dsdc_hash_ring_t _hash_ring;

    ptr<dsdcx_state2_t> _system_state;       // system state in XDR format
    ptr<dsdc_key_t>    _system_state_hash;  // hash of the above

    // only the first is active, the rest are backups.
    tailq<dsdcm_lock_server_t, &dsdcm_lock_server_t::_lnk> _lock_servers;
};

#endif /* _DSDC_MASTER_H */
