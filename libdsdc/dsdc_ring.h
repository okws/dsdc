// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-
/* $Id$ */

#ifndef _DSDC_HASHRING_H
#define _DSDC_HASHRING_H

#include "dsdc_util.h"
#include "dsdc_conn.h"

#include "itree.h"
#include "ihash.h"
#include "tame.h"

typedef callback<void, ptr<aclnt> >::ref aclnt_cb_t;

//-----------------------------------------------------------------------------

class connection_wrap_t : public virtual refcount {
public:
    virtual ~connection_wrap_t() { }

    virtual bool is_dead () = 0;
    virtual const str & remote_peer_id () const = 0;

    virtual ptr<connection_t> get_connection() { return nullptr; }
    virtual void get_connection(conn_cb_t cb, CLOSURE) { 
        (*cb)(get_connection()); 
    }
};

//-----------------------------------------------------------------------------

// a node in the consistent hash ring.  each slave process can register
// multiple nodes.
class dsdc_ring_node_t {
public:
    dsdc_ring_node_t (ptr<connection_wrap_t> w, const dsdc_key_t &k);
    ~dsdc_ring_node_t () { }

    // public fields for insert into itree
    dsdc_key_t _key;                         // the key for this node
    itree_entry<dsdc_ring_node_t> _lnk;      // for implementing itree

    ptr<connection_wrap_t> get_connection_wrap () { 
        return _connection_wrap; 
    }
    ptr<const connection_wrap_t> get_connection_wrap () const { 
        return _connection_wrap; 
    }

private:
    ptr<connection_wrap_t> _connection_wrap;
};

//-----------------------------------------------------------------------------

//
// special hash ring class with successor lookup function
//
class dsdc_hash_ring_t :
            public itree<dsdc_key_t, dsdc_ring_node_t,
            &dsdc_ring_node_t::_key,
            &dsdc_ring_node_t::_lnk, dsdck_compare_t>
{
public:
    dsdc_ring_node_t *successor (const dsdc_key_t &k) const;
    str fingerprint (str *long_fp) const;
private:
    str fingerprint_long () const;
    void fingerprint_long (vec<str> *v) const;
};

#endif
