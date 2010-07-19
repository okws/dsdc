// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-
/* $Id$ */

#ifndef _DSDC_HASHRING_H
#define _DSDC_HASHRING_H

#include "dsdc_util.h"

#include "itree.h"
#include "ihash.h"
#include "async.h"
#include "arpc.h"
#include "tame.h"

typedef callback<void, ptr<aclnt> >::ref aclnt_cb_t;

class aclnt_wrap_t {
public:
    virtual ~aclnt_wrap_t () {}
    virtual ptr<aclnt> get_aclnt () { return NULL; }
    virtual void get_aclnt (aclnt_cb_t cb, CLOSURE) { (*cb) (get_aclnt ()); }
    virtual bool is_dead () = 0;
    virtual const str & remote_peer_id () const = 0;
};

// a node in the consistent hash ring.  each slave process can register
// multiple nodes.
class dsdc_ring_node_t {
public:
    dsdc_ring_node_t (aclnt_wrap_t *w, const dsdc_key_t &k);
    ~dsdc_ring_node_t () { }

    // public fields for insert into itree
    dsdc_key_t _key;                         // the key for this node
    itree_entry<dsdc_ring_node_t> _lnk;      // for implementing itree

    aclnt_wrap_t * get_aclnt_wrap () { return _aclnt_wrap; }
    const aclnt_wrap_t * get_aclnt_wrap () const { return _aclnt_wrap; }

private:
    aclnt_wrap_t *_aclnt_wrap;
};

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
