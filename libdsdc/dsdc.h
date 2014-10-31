// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-
//-----------------------------------------------------------------------
/* $Id$ */

#ifndef _DSDC_SMARTCLI_H_
#define _DSDC_SMARTCLI_H_

// when we hit a major version it should go to 100000
#define DSDC_VERSION    200000

#include "async.h"
#include "arpc.h"
#include "qhash.h"
#include "crypt.h"
#include "sha1.h"
#include "tame.h"

#include "dsdc_prot.h"
#include "dsdc_ring.h"
#include "dsdc_state.h"
#include "dsdc_lock.h"
#include "dsdc_const.h"
#include "dsdc_stats.h"
#include "dsdc_format.h"
#include "dsdc_conn.h"

typedef dsdc::annotation::base_t annotation_t;

/**
 * @brief dsdc intelligent, which is the prefix for smart clients
 *
 * this class is a base class for any hostname/port pair that
 * we will maintain for the smart client to connect to
 */
class dsdci_srv_t : public connection_wrap_t, public virtual refcount {
public:
    dsdci_srv_t (const str &h, int p) ;
    virtual ~dsdci_srv_t ();

    const str &key () const { return _key; }
    virtual void connect (cbb cb, CLOSURE);

    void hold () { refcount_inc (); }
    void release () { _orphaned = true; refcount_dec (); }

    void hit_eof (ptr<bool> df); // call this when there is an EOF

    /**
     * some descendents will want to reestablish as soon as communication
     * is cut off (such as masters!)
     */
    virtual void eof_hook () {};

    /**
     * say if it's a master or slave connection (for logging)
     */
    virtual str typ () const { return "slave"; }


    /**
     * for aclnt_wrap virtual interface.  note that this interface is
     * not reliable! if no RPC over TCP connection is currently active,
     * then we cannot create a new TCP connection (since this function
     * has no callback) and therefore NULL will just be returned. It
     * is advised that the async version is always used, which is given
     * below.
     *
     * @ret the RPC client, if one was active. NULL if not
     *
     */
    ptr<connection_t> get_connection () { return _cli; }

    /**
     * call this function to get a new aclnt, so that you can make
     * RPC connections to this particular slave.
     *
     * @param cb callback to call with the resulting ptr<aclnt>, or NULL on err
     */
    void get_connection (conn_cb_t cb, CLOSURE);
    virtual bool is_dead () override;

    /**
     * a remote peer is identified by a <hostname>:<port>
     */
    const str &remote_peer_id () const { return _key; }

    typedef enum { CONN_NONE,
                   CONN_FAST,
                   CONN_SLOW } conn_state_t;

protected:
    void trigger_waiters();

public:
    const str _key;
protected:
    const str _hostname;
    const int _port;
    int _fd;

    ptr<axprt> _x;
    ptr<connection_t> _cli;
protected:
    ptr<bool> _destroyed;
    conn_state_t _conn_state;
    vec<evv_t> _waiters;
    bool _orphaned;
};

class dsdci_retry_srv_t : public dsdci_srv_t {
public:
    dsdci_retry_srv_t(const str& h, int p) : dsdci_srv_t(h,p) { }
    void eof_hook();
    void retry_loop(CLOSURE);
};

//
// dsci_master_t
//
//   maintains a persistent connection to a master, periodically downloading
//   the ring so that lookups and inserts are routed appropriately
//
class dsdci_master_t : public dsdci_retry_srv_t {
public:
    dsdci_master_t (const str &h, int p) : dsdci_retry_srv_t (h,p) {}

    str typ () const { return "master"; }

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

class dsdci_redis_slave_t : public dsdci_slave_t {
public:

    dsdci_redis_slave_t (const str &h, int p) : dsdci_slave_t (h, p) {}

    virtual void connect(cbb cb, CLOSURE) override;
    virtual bool is_dead() override;

protected:

    ptr<redis_connection_t> m_redisconn;

};

//
// dsdci_proxy_t
//
//  keep persistent connection open to the dsdc proxy if it exists
//
class dsdci_proxy_t : public dsdci_retry_srv_t {
public:
    dsdci_proxy_t(const str& h, int p) : dsdci_retry_srv_t(h,p) { }
    str typ() const { return "proxy"; }
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
typedef callback<void, ptr<dsdc_lock_acquire_res_t> >::ref
dsdc_lock_acquire_res_cb_t;

class dsdc_smartcli_t;


/**
 * A convenience class for simplifying puts/gets to and from the
 * DSDC via the smart client that you've already allocated. Once
 * this class has been instantiated, you shouldn't have to worry about
 * templatizing your put/get access methods into the smart client.  This
 * class will take care of converting your key and values into something
 * that DSDC can handle natively.
 *
 * This is the recommended way to access DSDC.
 */
template<class K, class V>
class dsdc_iface_t {
public:
    dsdc_iface_t (dsdc_smartcli_t *c, int t=-1) :
            _cli (c), time_to_expire(t) {}

    /**
     * Get an object from DSDC.
     *
     * @param k the key to get
     * @param cb the callback to call once its gotten (or error)
     * @param safe if on, route request through the master
     */
    void get (const K &k,
              typename callback<void, dsdc_res_t, ptr<V> >::ref cb,
              bool safe = false,
              const annotation_t *a = NULL,
              dsdc_cksum_t *cksum = NULL);

    /**
     * Put an object into DSDC.
     *
     * @param k the key to file the object under.
     * @param obj the object to store
     * @param cb get called back at cb with a status code
     * @param safe if on, route PUT through the master.
     */
    void put (const K &k, const V &obj, cbi::ptr cb = NULL,
              bool safe = false,
              const annotation_t *a = NULL,
              const dsdc_cksum_t *cks = NULL);

    /**
     * Remove an object from DSDC
     *
     * @param k the key of the object to remove
     * @param cb get called back at cb with a status code
     * @param safe if on, route remove through the master.
     */
    void remove (const K &k, cbi::ptr cb = NULL, bool safe = false,
                 const annotation_t *a = NULL);

    /**
     * @brief Acquire a lock from the DSDC lock server
     *
     * Acquire a lock from the DSDC lock server.  The salient
     * options to this operation are what kind of lock to acquire
     * (either shared for reading or exclusive for reading) and
     * also whether or not to block while acquiring it.  In the
     * former case, the lock manager will grant a read lock if
     * the lock is currently unheld, or its shared among other readers;
     * it will block (or fail) if a writer currently hold the lock.
     * The default is to always grab exclusive/write locks.
     *
     * Also possible is a feature for not-blocking when querying
     * the lock server, though this is not the default behavior.
     * In the block flag is turned off, then the RPC to the server
     * will immediately return, either with the lock if the acquisition
     * was successful, or without it if the lock is already held.
     *
     * As usual, the safe flag can be specified to go through the master
     * as opposed to using the Smart Client's state, but this feature
     * is especially overkill in the case of the lock server protocol,
     * which should result in a system that's more stable than
     * data-storing slaves.
     *
     * Also, specify a timeout with the lock call; this means that the
     * lock server will time the lock out after that many seconds.
     *
     * After everything is done, the client is called back with a
     * dsdc_lock_acquire_res_cb_t, which contains a status code
     * and, on success, a lock ID for this particular lock. The
     * client should keep this lock ID around and present it to the
     * server when the lock is going to be release.  There is nothing
     * to stop the client from fudging the lock ID, so clients
     * can steal locks in this way.  But we assume the everyone trusts
     * each other.
     *
     * Note that lock IDs should be nonces over the lifetime of the lock
     * server, so this should help in debugging.  That is, if you get
     * lock ID i for key K1, and lock ID j for K2, and you mix up which
     * is related to which, the lock server should keep you straight,
     * since it knows that i != j for its lifetime.
     *
     * @param k the key to file the lock under
     * @param cb get called back at cb with the status and a Lock ID
     * @param timeout time this lock out after timeout seconds
     * @param writer If on, get an exclusive lock; if off, a shared lock
     * @param block Whether to block or just fail without the lock.
     * @param safe if on, route request through the master.
     */
    void lock_acquire (const K &k, dsdc_lock_acquire_res_cb_t cb,
                       u_int timeout = 0, bool writer = true,
                       bool block = true, bool safe = false);

    /**
     * @brief Release a lock already held.
     *
     * Release a lock previously acquired. Will not block on the server
     * side (but will obviously have network latency). The arguments
     * given are the key the original lock was requested on, and the
     * lock ID returned by lock_acquire_res_cb_t.
     *
     * @param k the key of the lock to release
     * @param id the lock ID held for that key
     * @param cb get called back at cb with a status code.
     * @param safe if on, route release through the master.
     */
    void lock_release (const K &k, dsdcl_id_t id, cbi::ptr cb = NULL,
                       bool safe = false);

    /*
     * @brief figure out slave the key maps to
     *
     * Useful for debugging.
     *
     * @param key the key in question
     */
    str which_slave (const K &k);

private:
    dsdc_smartcli_t *_cli;
    int time_to_expire;
};

#define DSDC_RETRY_ON_STARTUP          0x1

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
    dsdc_smartcli_t (u_int o = 0, u_int to = dsdc_rpc_timeout)
            : _curr_master (NULL), _opts (o), _timeout (to) {}
    ~dsdc_smartcli_t ();

    // adds a master from a string only, in the form
    // <hostname>:<port>
    bool add_master (const str &m);

    // add a new master server to the smart client.
    // returns true if the insert succeeded (if the master is not
    // a duplicate) and false otherwise.
    bool add_master (const str &hostname, int port);

    // add a new dsdc proxy server, if this is specified, then all requests
    // coming into this smart client will go through it 
    bool add_proxy(const str& hostname, int port = -1);

    // initialize the smart client; get a callback with a "true" result
    // as soon as one master connection succeeds, or with a "false" result
    // after all connections fail.
    void init (evb_t::ptr ev, CLOSURE);

    // If all masters are dead, we shouldn't keep the stale version
    // of the ring around.  NOTE that slaves do somethind else -- they
    // do keep around the old cached state, so that way they don't all
    // dump their data!
    bool clean_on_all_masters_dead () const { return true; }

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
    void put (ptr<dsdc_put4_arg_t> arg, cbi::ptr cb = NULL, bool safe = false);
    void put (ptr<dsdc_put3_arg_t> arg, cbi::ptr cb = NULL, bool safe = false);
    void get (ptr<dsdc_key_t> key, dsdc_get_res_cb_t cb,
              bool safe = false, int time_to_expire=-1,
              const annotation_t *a = NULL, CLOSURE);
    void remove (ptr<dsdc_key_t> key, cbi::ptr cb = NULL, bool safe = false);
    void remove (ptr<dsdc_remove3_arg_t> arg, cbi::ptr cb = NULL,
                 bool safe = false);
    void mget (ptr<vec<dsdc_key_t> > keys, dsdc_mget_res_cb_t cb);
    void lock_acquire (ptr<dsdc_lock_acquire_arg_t> arg,
                       dsdc_lock_acquire_res_cb_t cb, bool safe = false);
    void lock_release (ptr<dsdc_lock_release_arg_t> arg,
                       cbi::ptr cb = NULL, bool safe = false, CLOSURE);

    // slightly more automated versions of the above; call xdr2str/str2xdr
    // automatically, and therefore less code for the app designer
    template<class T> void put2 (const dsdc_key_t &k, const T &obj,
                                 cbi::ptr cb = NULL, bool safe = false,
                                 const annotation_t *a = NULL,
                                 const dsdc_cksum_t *cks = NULL);

    template<class T, class A> dsdc_res_t 
    put2_helper (ptr<A> arg, const T &obj, cbi::ptr cb);

    template<class T>
    void get2 (ptr<dsdc_key_t> k,
               typename callback<void, dsdc_res_t, ptr<T> >::ref cb,
               bool safe = false, int time_to_expire= -1,
               const annotation_t *a = NULL,
               dsdc_cksum_t *cksum = NULL);

    // even more convenient version of the above!
    template<class K, class V> void
    put3 (const K &k, const V &obj, cbi::ptr cb = NULL,
          bool safe = false,
          const annotation_t *a = NULL,
          const dsdc_cksum_t *cksum = NULL);

    template<class K, class V> void
    get3 (const K &k, typename callback<void, dsdc_res_t, ptr<V> >::ref cb,
          bool safe = false, int time_to_expire = -1,
          const annotation_t *a = NULL,
          dsdc_cksum_t *cksum = NULL);

    template<class K> void
    remove3 (const K &k, cbi::ptr cb = NULL, bool safe = false,
             const annotation_t *a = NULL);

    template<class K> str
    which_slave3 (const K &k);

    template<class K> void
    lock_acquire3 (const K &k, dsdc_lock_acquire_res_cb_t cb, u_int timeout,
                   bool writer = true, bool block = true, bool safe = false);

    template<class K> void
    lock_release3 (const K &k, dsdcl_id_t id, cbi::ptr cb = NULL,
                   bool safe = false);

    str which_slave (const dsdc_key_t &k);

    static bool obj_too_big (const dsdc_obj_t &obj);


    /**
     * create a templated interface to this dsdc, which will spare you
     * from the xdr2btyes and bytes2xdr involved with the standard
     * interface.
     *
     * @return An interface object.
     */
    template<class K, class O>
    ptr<dsdc_iface_t<K,O> >
    make_interface (int time_to_expire=-1) {
        return New refcounted<dsdc_iface_t<K,O> > (this, time_to_expire);
    }

protected:
    // calls either with a timeout or no, depending on the value set
    // for '_timeout'
    void rpc_call (ptr<connection_t> cli,
                   u_int32_t procno, const void *in, void *out, aclnt_cb cb);

    // fulfill the virtual interface of dsdc_system_cache_t
    ptr<connection_t> get_primary ();
    ptr<connection_wrap_t> new_wrap (const str &h, int p,
                                     dsdc_slave_type_t slave_type) override;
    ptr<connection_wrap_t> new_lockserver_wrap (const str &h, int p);

    void pre_construct ();
    void post_construct ();

    void acquire_cb_1 (ptr<dsdc_lock_acquire_arg_t> arg,
                       dsdc_lock_acquire_res_cb_t cb,
                       ptr<connection_t> cli);

  

    //---------------------------------------------------------------------
    // change cache code

    // cc_t - temporary object useful for changing the cache by
    // issuing updates or deletes. see the next 4 functions
    // for where it's used.  should not be used anywhere else
    template<class T>
    struct cc_t {
        cc_t () {}
        cc_t (const dsdc_key_t &k, ptr<T> a, int p, cbi::ptr c)
                : key (k), arg (a), proc (p), cb (c), 
		  res (New refcounted<int> ()) {}

        ~cc_t () { if (cb) (*cb) (*res); }

        void set_res (int i) { *res = i; }

        dsdc_key_t key;
        ptr<T> arg;
        int proc;
        cbi::ptr cb;
        ptr<connection_t> cli;
        ptr<int> res;
    };

    template<class T> void
    change_cache (const dsdc_key_t &k, ptr<T> arg, int, cbi::ptr, bool);

    template<class T> void change_cache (ptr<cc_t<T> > cc, bool safe);
    template<class T> void change_cache_cb_2 (ptr<cc_t<T> > cc, clnt_stat err);
    template<class T> void change_cache_cb_1 (ptr<cc_t<T> > cc, 
                                              ptr<connection_t> cli);

    //
    // end change cache code
    //---------------------------------------------------------------------

    //-----------------------------------------------------------------------
    // init code
    //   required semantics: first master wins, but if all masters
    //   fail, then we're required to say that
    //

    // keep trying to connect to the master if it didn't work at first!
    // trigger 0 for "OK", 1 for "first to complete" and -1 for "fail"
    void master_connect (dsdci_master_t *m, evi_t ev, CLOSURE);

    void proxy_connect (dsdci_proxy_t *m, evi_t ev, CLOSURE);

    ptr<dsdci_proxy_t> get_proxy();

    // On init, we want to return success to the caller after we have
    // successfully initialized the hash ring.
    evv_t::ptr _poke_after_refresh;

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

    vec< ptr<dsdci_proxy_t> > _proxies;

    u_int _opts;
    u_int _timeout;
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
        if (show_debug (DSDC_DBG_LOW)) {
            warn << "RPC error in proc=" << cc->proc << ": " << err << "\n";
        }
        cc->set_res (DSDC_RPC_ERROR);
    }
}

template<class T> void
dsdc_smartcli_t::change_cache_cb_1 (ptr<cc_t<T> > cc, ptr<connection_t> cli)
{
    if (!cli) {
        cc->set_res (DSDC_NONODE);
        return;
    }

    rpc_call (cli, cc->proc, cc->arg, cc->res,
              wrap (this, &dsdc_smartcli_t::change_cache_cb_2<T>, cc));
}

template<class T> void
dsdc_smartcli_t::change_cache (ptr<cc_t<T> > cc, bool safe)
{
    ptr<dsdci_proxy_t> prx;
    if (safe) {
        change_cache_cb_1 (cc, get_primary ());
    } else if (_proxies.size() && (prx = get_proxy())) {
        prx->get_connection(wrap(this, 
                            &dsdc_smartcli_t::change_cache_cb_1<T>, cc));
    } else {

        dsdc_ring_node_t *n = _hash_ring.successor (cc->key);
        if (!n) {
            cc->set_res (DSDC_NONODE);
            return;
        }
        n->get_connection_wrap ()
        ->get_connection(wrap(this, 
                              &dsdc_smartcli_t::change_cache_cb_1<T>, cc));
    }
}

//
//
//-----------------------------------------------------------------------

//-----------------------------------------------------------------------

template<class T, class A> dsdc_res_t 
dsdc_smartcli_t::put2_helper (ptr<A> arg, const T &obj, cbi::ptr cb)
{
    dsdc_res_t err = DSDC_OK;
    if (!xdr2bytes (arg->obj, obj)) {
        err = DSDC_ERRENCODE;
    } else if (obj_too_big (arg->obj)) {
        err = DSDC_TOO_BIG;
    } else {
        put (arg, cb, false);
        err = DSDC_OK;
    }
    return err;
}

//-----------------------------------------------------------------------


template<class T> void
dsdc_smartcli_t::put2 (const dsdc_key_t &k, const T &obj,
                       cbi::ptr cb, bool safe,
                       const annotation_t *a,
                       const dsdc_cksum_t *ck)
{
    dsdc_res_t res = DSDC_OK;
    if (ck) {
        ptr<dsdc_put4_arg_t> arg4 = New refcounted<dsdc_put4_arg_t> ();
        arg4->key = k;
        annotation_t::to_xdr (a, &arg4->annotation);
        arg4->checksum.alloc ();
        *arg4->checksum = *ck;
        res = put2_helper (arg4, obj, cb);
    } else if (a) {
        ptr<dsdc_put3_arg_t> arg3 = New refcounted<dsdc_put3_arg_t> ();
        arg3->key = k;
        annotation_t::to_xdr (a, &arg3->annotation);
        res = put2_helper (arg3, obj, cb);
    } else {
        // Use compatibility layer if not using annotations
        ptr<dsdc_put_arg_t> arg = New refcounted<dsdc_put_arg_t> ();
        arg->key = k;
        res = put2_helper (arg, obj, cb);
    }

    if (res != DSDC_OK)
        cb(res);
}

//
//-----------------------------------------------------------------------

//-----------------------------------------------------------------------
// even lazier!
//
template<class K, class V> void
dsdc_smartcli_t::get3 (const K &k,
                       typename callback<void, dsdc_res_t, ptr<V> >::ref cb,
                       bool safe, int time_to_expire,
                       const annotation_t *a,
                       dsdc_cksum_t *out)
{
    get2<V> (mkkey_ptr (k), cb, safe, time_to_expire, a, out);
}

template<class K> str
dsdc_smartcli_t::which_slave3 (const K &k)
{
    dsdc_key_t dk;
    mkkey (&dk, k);
    return which_slave (dk);
}

template<class K, class V> void
dsdc_smartcli_t::put3 (const K &k, const V &obj, cbi::ptr cb, bool safe,
                       const annotation_t *a,
                       const dsdc_cksum_t *cksm)
{
    put2 (mkkey (k), obj, cb, safe, a, cksm);
}

template<class K> void
dsdc_smartcli_t::remove3 (const K &k, cbi::ptr cb, bool safe,
                          const annotation_t *a)
{
    if (!a) {
        remove (mkkey_ptr (k), cb, safe);
    } else {
        ptr<dsdc_remove3_arg_t> arg = New refcounted<dsdc_remove3_arg_t> ();
        mkkey (&arg->key, k);
        a->to_xdr (&arg->annotation);
        remove (arg, cb, safe);
    }
}

template<class K> void
dsdc_smartcli_t::lock_release3 (const K &k, dsdcl_id_t id, cbi::ptr cb,
                                bool safe)
{
    ptr<dsdc_lock_release_arg_t> arg =
        New refcounted<dsdc_lock_release_arg_t> ();
    mkkey<K> (&arg->key, k);
    arg->lockid = id;
    lock_release (arg, cb, safe);
}

template<class K> void
dsdc_smartcli_t::lock_acquire3 (const K &k, dsdc_lock_acquire_res_cb_t cb,
                                u_int timeout, bool writer, bool block,
                                bool safe)
{
    ptr<dsdc_lock_acquire_arg_t> arg =
        New refcounted<dsdc_lock_acquire_arg_t> ();
    mkkey<K> (&arg->key, k);
    arg->writer = writer;
    arg->block = block;
    arg->timeout = timeout;
    lock_acquire (arg, cb, safe);
}

template<class K, class V> str
dsdc_iface_t<K,V>::which_slave (const K &k)
{
    return _cli->template which_slave3<K> (k);
}

template<class K, class V> void
dsdc_iface_t<K,V>::get (const K &k,
                        typename callback<void, dsdc_res_t, ptr<V> >::ref cb,
                        bool safe,
                        const annotation_t *a,
                        dsdc_cksum_t *cksum)
			
{ _cli->template get3<K,V> (k, cb, safe, time_to_expire, a, cksum); }

template<class K, class V> void
dsdc_iface_t<K,V>::put (const K &k, const V &obj, cbi::ptr cb, bool safe,
                        const annotation_t *a, const dsdc_cksum_t *cks)
{ _cli->put3 (k, obj, cb, safe, a, cks); }

template<class K, class V> void
dsdc_iface_t<K,V>::remove (const K &k, cbi::ptr cb, bool safe,
                           const annotation_t *a)
{ _cli->remove3 (k, cb, safe, a); }

template<class K, class V> void
dsdc_iface_t<K,V>::lock_acquire (const K &k, dsdc_lock_acquire_res_cb_t cb,
                                 u_int timeout, bool writer, bool block,
                                 bool safe)
{ _cli->lock_acquire3 (k, cb, timeout, writer, block, safe); }

template<class K, class V> void
dsdc_iface_t<K,V>::lock_release (const K &k, dsdcl_id_t id,
                                 cbi::ptr cb, bool safe)
{
    _cli->lock_release3 (k, id, cb, safe);
}


//
//-----------------------------------------------------------------------


//-----------------------------------------------------------------------   
// get2
//

template<class T>
class get2_tame_helper {
public:
    get2_tame_helper () {}
    void fn (dsdc_smartcli_t *cli,
               ptr<dsdc_key_t> k,
               typename callback<void, dsdc_res_t, ptr<T> >::ref cb,
               bool safe = false, int time_to_expire= -1,
               const annotation_t *a = NULL,
               dsdc_cksum_t *cksum = NULL,
               CLOSURE);
};

template<class T> void 
dsdc_smartcli_t::get2 (ptr<dsdc_key_t> k,
                       typename callback<void, dsdc_res_t, ptr<T> >::ref cb,
                       bool safe, int time_to_expire,
                       const annotation_t *a,
                       dsdc_cksum_t *cksum)
{
    get2_tame_helper<T> th;
    th.fn (this, k, cb, safe, time_to_expire, a, cksum);
}

//
//-----------------------------------------------------------------------

// tame-generated from dsdc_tamed.h
#include "dsdc_tamed.h"

#endif /* _DSDC_SMARTCLI_H_ */
