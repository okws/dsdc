
#include "dsdc_lock.h"
#include "dsdc_util.h"
#include "dsdc_const.h"

#define __STDC_FORMAT_MACROS
#include <inttypes.h>

dsdcl_id_t g_serial_no = 0;

static dsdcl_id_t nxt_id () { return ++g_serial_no; }

dsdc_lock_t::dsdc_lock_t (const dsdc_key_t &k, dsdcl_mgr_t *m)
  : _writer (NULL) , _destroyed (New refcounted<bool> (false)),
    _mgr (m), _leave_in_hash (false)
{
  memcpy (_key.base (), k.base (), k.size ());
  assert (!_mgr->find_lock (_key));
  _mgr->insert (this);
}

dsdc_lock_t::~dsdc_lock_t ()
{
  if (show_debug (4))
    warn ("Key %s: lock deleted\n", key_to_str (_key).cstr ());

  dsdcl_waiter_t *p, *n;

  // should only happen when we delete the grandparent lock manager
  if (_waiters.first && show_debug (DSDC_DBG_MED)) 
    warn ("Key %s: waiters left in queue on delete\n", 
	  key_to_str (_key).cstr ());

  for (p = _waiters.first ; p ; p = n) {
    n = _waiters.next (p);
    delete p;
  }

  if (!_leave_in_hash)
    _mgr->remove (this);

  *_destroyed = true;
}

dsdcl_waiter_t::~dsdcl_waiter_t ()
{
  // signal failure if no success has been signaled.
  if (_cb) 
    (*_cb) (0);
}

void
dsdcl_waiter_t::got_lock (dsdcl_id_t i)
{
  if (_cb) {
    // Be a bit paranoid here; there might some weird case in which
    // getting a lock triggers the deletion of the lock manager and
    // therefore the deletion of this lock and therefore the deletion
    // of this waiter.
    cb_lid_t::ptr c = _cb;
    _cb = NULL;
    (*c) (i);
  }
}

void
dsdc_lock_t::acquire (bool writer, u_int timeout, cb_lid_t cb)
{
  dsdcl_id_t i;
  if ((i = acquire_noblock (writer, timeout))) {
    (*cb) (i);
  } else {
    dsdcl_waiter_t *w = New dsdcl_waiter_t (writer, timeout, cb);
    _waiters.insert_tail (w);
    if (!writer)
      _r_waiters.insert_tail (w);
  }
}

bool
dsdc_lock_t::release (dsdcl_id_t l)
{
  dsdcl_holder_t *h = NULL;
  bool ret = true;
  if ((h = _writer)) {
    if (l != h->id ()) {
      if (show_debug (DSDC_DBG_LOW))
	warn ("Key %s: release of write lock failed; "
	      "expected ID %" PRIx64 ", got ID 0x%" PRIx64 "\n",
	      key_to_str (_key).cstr (), h->id (), l);
      ret = false;
      h = NULL; /* set h to NULL so it's not deleted ... */
    } else {
      h = _writer;
      _writer = NULL;
    }
  } else {
    if (!(h = _readers[l])) {
      if (show_debug (DSDC_DBG_LOW)) 
	warn ("Key %s: no lock found for lock ID 0x%" PRIx64 "\n",
	      key_to_str (_key).cstr (), l);
      ret = false;
    } else {
      _readers.remove (h);
    }
  }
  if (h) {
    h->cancel_timeout ();
    delete h;
  }

  // Keep in mind that process_queue can delete the 'this' object 
  // from under us, so make sure we never access internal class variables
  // after we call it.
  process_queue ();

  return ret;
}

dsdcl_id_t 
dsdc_lock_t::acquire_noblock (bool writer, u_int timeout)
{
  // If anyone has the write lock, or we wanted the write lock but
  // there are readers, then we have to fail immediately.
  if (_writer || (writer && _readers.size () > 0))
    return 0;

  dsdcl_holder_t *h = new_holder (writer, timeout);
  return h->id ();
}

dsdcl_holder_t *
dsdc_lock_t::new_holder (bool writer, u_int timeout)
{
  dsdcl_id_t id = nxt_id ();
  dsdcl_holder_t * h = New dsdcl_holder_t (id, writer, timeout);
  
  assert (!_writer);
  if (writer) {
    assert (_readers.size () == 0);
    _writer = h;
  } else {
    _readers.insert (h);
  }
  h->set_timeout (wrap (this, &dsdc_lock_t::remove_holder, h, 
			_destroyed, true));
  return h;
}

dsdcl_holder_t *
dsdc_lock_t::waiter_to_holder (dsdcl_waiter_t *w)
{
  dsdcl_holder_t *h = new_holder (w->is_writer (), w->timeout ());
  w->got_lock (h->id ());
  _waiters.remove (w);
  if (!w->is_writer ())
    _r_waiters.remove (w);
  delete w;
  return h;
}

void
dsdcl_holder_t::cancel_timeout ()
{
  assert (_timer);
  timecb_remove (_timer);
}

//
// At this point a lock has just been released (whether a write lock or
// a read lock).  So we go through and see if we can issue the lock to
// any of the patient waiters.  If it turns out that no one is waiting, and
// no one has the lock, we go ahead and delete ourselves in this call.
// Thus, functions who call process_queue should assume that it will delete
// the this object.
//
void
dsdc_lock_t::process_queue ()
{
  if (is_locked ())
    return;

  dsdcl_waiter_t *w = _waiters.first;
  dsdcl_waiter_t *nxt;
  if (w) {
    if (w->is_writer ()) {
      waiter_to_holder (w);
    } else {
      for ( w = _r_waiters.first ; w ; w = nxt) {
	nxt = _r_waiters.next (w);
	waiter_to_holder (w);
      }
    }
  }
  // this is somewhat paranoid, but better safe than sorry
  if (!is_locked () && !_waiters.first)
    delete this;
}

bool
dsdc_lock_t::is_locked () const
{
  return (_writer || _readers.size () > 0);
}

void
dsdc_lock_t::remove_holder (dsdcl_holder_t *h, ptr<bool> df, bool timed_out)
{
  // this lock might have been destroyed
  if (*df)
    return;

  if (!timed_out)
    h->cancel_timeout ();
  else if (show_debug (DSDC_DBG_LOW)) {
    warn ("Key %s: lock timed out for ID 0x%" PRIx64 "\n", 
	  key_to_str (_key).cstr (), h->id ());
  }
  if (h->is_writer ()) {
    _writer = NULL;
  } else {
    _readers.remove (h);
  }
  process_queue ();
  delete h;
}

void
dsdcl_holder_t::set_timeout (cbv::ptr cb)
{
  _timer = delaycb (_timeout, 0, cb);
}

dsdcl_holder_t::dsdcl_holder_t (dsdcl_id_t i, bool w, u_int to)
  : _id (i), _timer (NULL), _writer (w), _timein (timenow), 
    _timeout (to ? to : dsdcl_default_timeout),
    _destroyed (New refcounted<bool> (false))
{}

static void
acquire_reply (svccb *sbp, dsdcl_id_t i)
{
  dsdc_lock_acquire_res_t res (i == 0 ? DSDC_LOCKED : DSDC_OK);
  if (i > 0) 
    *res.lockid = i;
  sbp->replyref (res);
}

static void
acquire_cb (svccb *sbp, dsdcl_id_t i)
{
  acquire_reply (sbp, i);
}

void
dsdcl_mgr_t::acquire (svccb *sbp)
{
  dsdc_lock_acquire_arg_t *arg = sbp->Xtmpl getarg<dsdc_lock_acquire_arg_t> ();
  dsdc_lock_t *l = find_lock (arg->key);
  dsdcl_id_t i;
  if (!l) {
    // Making a new lock takes care of the insertion into our _locks
    // table
    l = New dsdc_lock_t (arg->key, this);
  }
  if (arg->block) {
    l->acquire (arg->writer, arg->timeout, wrap (acquire_cb, sbp));
  } else {
    i = l->acquire_noblock (arg->writer, arg->timeout);
    acquire_reply (sbp, i);
  }
}

void
dsdcl_mgr_t::release (svccb *sbp)
{
  dsdc_lock_release_arg_t *arg = sbp->Xtmpl getarg<dsdc_lock_release_arg_t> ();
  dsdc_lock_t *l = find_lock (arg->key);
  dsdc_res_t res = DSDC_NOTFOUND;
  if (!l) {
    if (show_debug (DSDC_DBG_LOW))
      warn ("Key %s: no lock found\n", key_to_str (arg->key).cstr ());
  } else if (!l->release (arg->lockid)) {

    if (show_debug (DSDC_DBG_MED))
      // This warning at level 2, since a warning is already sounded in
      // l->release() if something weird happened.
      warn ("Key %s: no lock for ID 0x%" PRIx64 "\n", key_to_str (arg->key).cstr (), 
	    arg->lockid);

  } else
    res = DSDC_OK;
  sbp->replyref (res);
}

static void 
delete_lock (dsdc_lock_t *l) 
{ 
  l->set_leave_in_hash ();
  delete l; 
}

dsdcl_mgr_t::~dsdcl_mgr_t ()
{
  _locks.traverse (wrap (delete_lock));
}

