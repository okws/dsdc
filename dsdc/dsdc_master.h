// -*-c++-*-
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

// one of these objects is allocated for each extern client served;
// i.e., there is one per incoming TCP connection. when the
// external client goes away, so, too, does this thing.
class dsdcm_client_t {
public:
  dsdcm_client_t (dsdc_master_t *m, int _fd, const str &h);
  ~dsdcm_client_t () ;

  void dispatch (svccb *b);          // handle a request
  list_entry<dsdcm_client_t> _lnk;   // for insert into a list of clients

  dsdc_master_t *get_master () { return _master; }
  const str &hostname () const { return _hostname; }

protected:

  void handle_heartbeat (svccb *b);
  void handle_register (svccb *b);

  // if this client has registered as a slave, then this pointer field
  // will be set.  we set up bidirectional pointers here.
  dsdcm_slave_t *_slave;  

  dsdc_master_t *_master; // master objet
  int _fd;                // the client's fd
  ptr<axprt> _x;          // a wrapper around the fd for the client
  ptr<asrv> _asrv;        // async RPC server
  str _hostname;          // hostname / port of client
};

//
// slaves start out as regular clients, but are promoted when a register 
// call is made. 
//
class dsdcm_slave_t : public aclnt_wrap_t {
public:
  dsdcm_slave_t (dsdcm_client_t *c, ptr<axprt> x) ;
  ~dsdcm_slave_t () ;

  ptr<aclnt> get_aclnt () { return _clnt_to_slave; }
  void handle_heartbeat () { _last_heartbeat = timenow; }
  void init (const dsdcx_slave_t &keys);
  const str &hostname () const { return _client->hostname (); }

  void get_xdr_repr (dsdcx_slave_t *o) { *o = _xdr_repr; }

  bool is_dead ();                    // if no heartbeat, assume dead
  list_entry<dsdcm_slave_t> _lnk;

private:
  dsdcx_slave_t _xdr_repr;           // XDR representation of us
  dsdcm_client_t *_client;           // associated client object
  ptr<aclnt> _clnt_to_slave;         // RPC client for talking to slave
  vec<dsdc_ring_node_t *> _nodes;  // this slave's nodes in the ring
  time_t _last_heartbeat;            // last reported heartbeat
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
    _port (p > 0 ? p : dsdc_port), _lfd (-1) {}
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

  void insert_slave (dsdcm_slave_t *sl)
  { _slaves.insert_head (sl); }
  void remove_slave (dsdcm_slave_t *sl)
  { _slaves.remove (sl); }

  // given a key, look in the consistent hash ring for a corresponding
  // node, and then get the ptr<aclnt> that corresponds to the remote
  // host
  dsdc_res_t get_aclnt (const dsdc_key_t &k, ptr<aclnt> *cli);

  void handle_get (svccb *b);
  void handle_remove (svccb *b);
  void handle_put (svccb *b);
  void handle_getstate (svccb *b);

  void broadcast_newnode (const dsdcx_slave_t &x, dsdcm_slave_t *skip);

  // manage the system state
  void reset_system_state ();
  void compute_system_state ();

  str startup_msg () const 
  {
    return strbuf ("master listening on %s:%d", dsdc_hostname.cstr (), _port);
  }
  str progname_xtra () const { return "-M"; }
private:

  void broadcast_deletes (const dsdc_key_t &k, dsdcm_slave_t *skip);

  int _port;                         // the port it should listen on
  int _lfd;                          // listen file descriptor
  ptr<asrv> _srv;                    // for serving clients + slaves

  // keep track of all active clients (including slaves)
  list<dsdcm_client_t, &dsdcm_client_t::_lnk> _clients;

  // keep track of all of the slave pointers
  list<dsdcm_slave_t, &dsdcm_slave_t::_lnk> _slaves;

  // the itree containing all of the nodes in the consistent hash ring
  // for all of the slaves.  note that every slave in the ring can
  // hold many nodes in the ring; it's up to each slave.  the more
  // nodes that the slave has, the more load it will bear.
  dsdc_hash_ring_t _hash_ring;

  ptr<dsdcx_slaves_t> _system_state;      // system state in XDR format
  ptr<dsdc_key_t>     _system_state_hash; // hash of the above
};

#endif /* _DSDC_MASTER_H */
