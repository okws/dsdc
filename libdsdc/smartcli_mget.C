
#include "dsdc.h"
#include "dsdc_const.h"
#include "async.h"

struct mget_state_t;

struct mget_batch_t {
  mget_batch_t (const str &s, aclnt_wrap_t *w, ptr<mget_state_t> h) 
    : node (s), aclw (w), hold (h) {}

  void mget ();
  void mget_cb1 (ptr<aclnt> c);
  void mget_cb2 (clnt_stat err);

  str node;
  aclnt_wrap_t *aclw;

  dsdc_mget_arg_t arg;    // argument to send to slave
  vec<u_int> positions;   // corresponding positions list
  ptr<mget_state_t> hold; // hold on until we're done
  dsdc_mget_res_t res;    // where to put our local results

  ihash_entry<mget_batch_t> link;
};

class mget_state_t : public virtual refcount {
public:
  mget_state_t (ptr<vec<dsdc_key_t> > k, dsdc_mget_res_cb_t c) 
    : keys (k), n (k->size ()), res (New refcounted<dsdc_mget_res_t> ()),
      cb (c) 
  { res->setsize (n); }

  ~mget_state_t ();

  void go (const dsdc_hash_ring_t &r);
  void set (const dsdc_get_res_t &r, u_int p) { (*res)[p].res = r; }


private:

  void load_batches (const dsdc_hash_ring_t &r);
  void dispatch_slaves ();
  void dispatch_slave (mget_batch_t *batch);

  ptr<vec<dsdc_key_t> > keys;
  size_t n;
  ptr<dsdc_mget_res_t> res;
  dsdc_mget_res_cb_t cb;
  ihash<str, mget_batch_t, &mget_batch_t::node, &mget_batch_t::link> batches;
};

mget_state_t::~mget_state_t ()
{
  batches.deleteall ();
  (*cb) (res);
}

void
dsdc_smartcli_t::mget (ptr<vec<dsdc_key_t> >keys, dsdc_mget_res_cb_t cb)
{
  ptr<mget_state_t> state = New refcounted<mget_state_t> (keys, cb);
  state->go (_hash_ring);
}

void
mget_state_t::go (const dsdc_hash_ring_t &r)
{
  load_batches (r);
  dispatch_slaves ();
}

void
mget_batch_t::mget_cb2 (clnt_stat err)
{
  size_t sz = positions.size ();
  dsdc_get_res_t err_res;

  if (err) {
    err_res.set_status (DSDC_RPC_ERROR); 
    *(err_res.err) = err;
  }

  for (u_int i = 0; i < sz; i++) {
    if (err) {
      hold->set (err_res, positions[i]);
    } else {
      hold->set (res[i].res, positions[i]);
    }
  }

  // might actually free us, so don't access any class variables
  // after unsetting the *hold* reference count
  hold = NULL; 
}

void
mget_batch_t::mget_cb1 (ptr<aclnt> c)
{
  c->call (DSDC_MGET, &arg, &res, wrap (this, &mget_batch_t::mget_cb2));
}

void
mget_batch_t::mget ()
{
  aclw->get_aclnt (wrap (this, &mget_batch_t::mget_cb1));
}

void
mget_state_t::dispatch_slave (mget_batch_t *batch)
{
  batch->mget ();
}

void
mget_state_t::dispatch_slaves ()
{
  batches.traverse (wrap (this, &mget_state_t::dispatch_slave));
}

void
mget_state_t::load_batches (const dsdc_hash_ring_t &r)
{
  for (u_int i = 0; i < n; i++) {
    dsdc_key_t k = (*keys)[i];
    dsdc_ring_node_t *n = r.successor (k);
    (*res)[i].key = k;
    if (!n) {
      (*res)[i].res.set_status (DSDC_NONODE);
    } else {
      aclnt_wrap_t *w = n->get_aclnt_wrap ();
      mget_batch_t *batch;
      str id = w->remote_peer_id ();
      if (!(batch = batches[id])) {
	batch = New mget_batch_t (id, w, mkref (this));
	batches.insert (batch);
      }
      batch->arg.push_back (k);
      batch->positions.push_back (i);
    }
  }
}

