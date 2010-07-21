// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "dsdc_ring.h"
#include "crypt.h"

dsdc_ring_node_t::dsdc_ring_node_t (ptr<aclnt_wrap_t> w, const dsdc_key_t &k)
        :  _aclnt_wrap (w)
{
    memcpy (_key.base (),  k.base (), k.size ());
}

//-----------------------------------------------------------------------
//
// lookup a key in the consistent hash ring.

dsdc_ring_node_t *
dsdc_hash_ring_t::successor (const dsdc_key_t &k) const
{
    dsdc_ring_node_t *ret = NULL;
    dsdc_ring_node_t *n = root ();

    if (!n && show_debug (DSDC_DBG_MED)) {
        warn ("DSDC ring is empty; successor lookup will fail for key: %s\n",
              key_to_str (k).cstr ());
    }

    while (n) {
        // i'm pretty sure that res > 0 implies that
        // n->get_key () < k, but let's check on that...
        int res = dsdck_cmp (n->_key, k);
        if (res > 0) {
            n = left (n);
        } else if (res < 0) {
            ret = n;
            n = right (n);
        } else {
            // res == 0; not very likely
            return n;
        }
    }

    // compute wraparound; extra tree traverse, but not bad if
    // ammortized
    if (!ret) {
        n = root ();
        while (n) {
            ret = n;
            n = right (n);
        }
    }

    if (show_debug (DSDC_DBG_HI)) {
        warn ("successor lookup: %s -> %s\n",
              key_to_str (k).cstr (),
              ret ? key_to_str (ret->_key).cstr () : "<null>");
    }

    return ret;
}

//
//-----------------------------------------------------------------------

//-----------------------------------------------------------------------

str
dsdc_hash_ring_t::fingerprint (str *long_fp) const
{
    str lfp = fingerprint_long ();
    if (long_fp) { *long_fp = lfp; }
    char buf[sha1::hashsize];
    sha1_hash (buf, lfp.cstr (), lfp.len ());
    return str (buf, sha1::hashsize);
}

//-----------------------------------------------------------------------

str
dsdc_hash_ring_t::fingerprint_long () const
{
    vec<str> v;
    fingerprint_long (&v);
    strbuf b;
    for (size_t i = 0; i < v.size (); i++) {
        if (i > 0) b << ",";
        b << v[i];
    }
    return b;
}

//-----------------------------------------------------------------------

void
dsdc_hash_ring_t::fingerprint_long (vec<str> *vc) const
{
    const dsdc_ring_node_t *n, *nn;
    for (n = first (); n; n = nn) {
        nn = next (n);
        str k = armor32 (n->_key.base (), n->_key.size ());
        str v;
        ptr<const aclnt_wrap_t> w = n->get_aclnt_wrap ();
        if (w) { v = w->remote_peer_id (); }
        if (k && v) {
            strbuf b ("%s:%s", k.cstr (), v.cstr ());
            vc->push_back (b);
        }
    }
}

//-----------------------------------------------------------------------
