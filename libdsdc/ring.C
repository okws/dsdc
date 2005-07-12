
#include "dsdc_ring.h"

dsdc_ring_node_t::dsdc_ring_node_t (aclnt_wrap_t *w, const dsdc_key_t &k)
  :  _aclnt_wrap (w)
{
  memcpy (_key.base (),  k.base (), k.size ());
}

//-----------------------------------------------------------------------
//
// lookup a key in the consistent hash ring.

dsdc_ring_node_t *
dsdc_hash_ring_t::successor (const dsdc_key_t &k)
{
  dsdc_ring_node_t *ret = NULL;
  dsdc_ring_node_t *n = root ();

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

  if (show_debug (3)) {
    warn ("successor lookup: %s -> %s\n", 
	  key_to_str (k).cstr (), 
	  ret ? key_to_str (ret->_key).cstr () : "<null>");
  }

  return ret;
}

//
//-----------------------------------------------------------------------

