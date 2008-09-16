
// -*-c++-*-
/* $Id$ */

#ifndef _DSDC_LOCK_H
#define _DSDC_LOCK_H

#include "dsdc_prot.h"
#include "async.h"
#include "arpc.h"

typedef u_int64_t dsdcl_id_t;
typedef callback<void, dsdcl_id_t>::ref cb_lid_t;

class dsdcl_waiter_t {
public:
    dsdcl_waiter_t (bool w, u_int to, cb_lid_t c) :
            _writer (w), _timeout (to), _cb (c) {}
    ~dsdcl_waiter_t ();
    bool is_writer () const { return _writer; }
    u_int timeout () const { return _timeout; }
    void got_lock (dsdcl_id_t i);
    tailq_entry<dsdcl_waiter_t> _lnk;
    tailq_entry<dsdcl_waiter_t> _r_lnk;
private:
    bool _writer;
    u_int _timeout;
    cb_lid_t::ptr _cb;
};

class dsdcl_holder_t {
public:
    dsdcl_holder_t (dsdcl_id_t i, bool w, u_int timeout = 0);
    dsdcl_id_t _id;
    ihash_entry<dsdcl_holder_t> _hlnk;
    void set_timeout (cbv::ptr cb);
    ptr<bool> destroyed_flag () { return _destroyed; }
    void cancel_timeout ();
    bool is_writer () const { return _writer; }
    dsdcl_id_t id () const { return _id; }

private:
    timecb_t  *_timer;
    bool      _writer;
    time_t    _timein;
    u_int     _timeout;
    ptr<bool> _destroyed;
};

class dsdcl_mgr_t;

class dsdc_lock_t {
public:
    dsdc_lock_t (const dsdc_key_t &k, dsdcl_mgr_t *m);
    ~dsdc_lock_t ();
    dsdc_key_t _key;
    ihash_entry<dsdc_lock_t> _hlnk;
    dsdcl_id_t acquire_noblock (bool writer, u_int timeout);
    void acquire (bool writer, u_int timeout, cb_lid_t cb);
    bool release (dsdcl_id_t l);
    void remove_holder (dsdcl_holder_t *h, ptr<bool> df, bool timed_out);
    bool is_locked () const ;
    void process_queue ();
    void set_leave_in_hash () { _leave_in_hash = true; }
private:
    dsdcl_holder_t *new_holder (bool w, u_int timeout);
    dsdcl_holder_t *waiter_to_holder (dsdcl_waiter_t *w) ;

    // If a writer holds the lock, it is exclusively set here
    dsdcl_holder_t        *_writer;

    // If several readers share a lock, they are represented in the
    // following hash table.
    ihash<dsdcl_id_t, dsdcl_holder_t,
    &dsdcl_holder_t::_id, &dsdcl_holder_t::_hlnk> _readers;

    // a list of all waiters
    tailq<dsdcl_waiter_t, &dsdcl_waiter_t::_lnk> _waiters;

    // list of just the waiters for a shared/read lock
    tailq<dsdcl_waiter_t, &dsdcl_waiter_t::_r_lnk> _r_waiters;

    ptr<bool> _destroyed;
    dsdcl_mgr_t *_mgr;

    // on if we should leave ourselves in the hash upon deletion;
    // only used when destroying the lock manager (wherein the lock
    // manager needs to safely traverse the locks hash
    bool _leave_in_hash;
};

/**
 * A lock manager class for DSDC.  Implements a simple RPC-based locking
 * interface, with exclusive (write) locks and also shared (read) locks.
 * Also offers the ability to not block when waiting for a lock -- either
 * to acquire it or just to return without it. Useful for serializing
 * access to DSDC for more complex data structures.
 *
 * All locks timeout after a given interval, which can be set arbitrarily
 * high on a per-lock basis with the acquire call.
 *
 * The interface is via the acquire(), release() pair, who in turn
 * follow the interface given in dsdc_prot.x
 *
 */
class dsdcl_mgr_t {
public:
    dsdcl_mgr_t () {}
    ~dsdcl_mgr_t ();
    void acquire (svccb *sbp);
    void release (svccb *sbp);

    friend class dsdc_lock_t;
private:
    // dsdc_lock_t should be able to access these, but no one who
    // is just using the public interface to this class.
    dsdc_lock_t *find_lock (const dsdc_key_t &k) { return _locks[k]; }
    void insert (dsdc_lock_t *l) { _locks.insert (l); }
    void remove (dsdc_lock_t *l) { _locks.remove (l); }

    ihash<dsdc_key_t, dsdc_lock_t,
    &dsdc_lock_t::_key, &dsdc_lock_t::_hlnk> _locks;
};

#endif /* _DSDC_LOCK_H */
