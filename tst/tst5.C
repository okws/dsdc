
#include "dsdc_util.h"
#include "dsdc.h"
#include "tst_prot.h"
#include "async.h"
#include "crypt.h"
#include "parseopt.h"
#include "rxx.h"
#include "dsdc_prot.h"
#include "dsdc_const.h"
#include "aios.h"
#include "dsdc_lock.h"
#include "dsdc_stats.h"

#include <inttypes.h>

typedef enum { NONE = 0,
	       GET = 1,
	       PUT = 2 } tst_mode_t;

#define LOCK_SHARED  (1 << 0)
#define LOCK_NO_BLOCK (1 << 1)

bool tst2_done = false;
int tst2_cbct = 0; // callback count

ptr<dsdc_iface_t<tst_key_t, tst_obj_checked_t> > cli;
dsdc_smartcli_t *sc;


static void
compute_checksum (tst_obj_checked_t *u)
{
  sha1_hashxdr (u->checksum.base (), u->obj);
}

static bool
check_obj (const tst_obj_checked_t *o)
{
  char digest[sha1::hashsize];
  sha1_hashxdr (digest, o->obj);
  return (memcmp (digest, o->checksum.base (), sha1::hashsize) == 0);
}

static void
generate_kv (tst_key_t *k, str *v)
{
  *k =  ( rand () % INT_MAX );

  u_int sz = rand () % 1000;

  mstr m (sz);
  int shift = 0;
  u_int32_t w = 0;
  for (u_int i = 0 ; i < sz; i ++) {
    if (shift == 0) 
      w = rand ();
    m[i] = (w >> shift) & 0xff;
    shift = (shift + 8 ) % 32;
  }
  *v = armor64 (m);
}


static void
usage ()
{
  warn << "usage: " << progname << " [-d] m1:p1 m2:p2 m3:p3 ...\n";
  exit (1);
}

static void
tst2_exit ()
{
  if (!tst2_cbct)
    exit (0);
  tst2_done = true;
}

static void srdline ();

static void
cb_done ()
{
  if (--tst2_cbct && tst2_done)
    exit (0);
}

static void
put_cb (str mapping, int res)
{
  if (res != DSDC_REPLACED && res != DSDC_INSERTED) {
    warn << "** PUT:  DSDC Error " << res << " in insert: " << mapping << "\n";
  } else {
    aout << "PUT: " << mapping << " (rc=" << res << ")\n";
  }
  cb_done ();
}

static void
put (tst_key_t k, str v, bool safe, int annt = -1)
{
  tst_obj_checked_t obj;
  obj.obj.key = k;
  obj.obj.val = v;

  compute_checksum (&obj);

  // for debug purposes
  str tmp = key_to_str (obj.checksum);
  strbuf mapping ("%d -> %s", k, tmp.cstr ());

  annotation_t *a = NULL;
  if (annt >= 0) 
    a = dsdc::annotation::collector.int_alloc (annt);
  
  tst2_cbct++;
  cli->put (k, obj, wrap (put_cb, str (mapping)), safe, a);
}

static void
get_cb (tst_key_t k, dsdc_res_t status, ptr<tst_obj_checked_t> obj)
{
  switch (status) {
  case DSDC_NOTFOUND:
    aout << strbuf ("GET: %d -> <null> (NOT FOUND)\n", k);
    break;
  case DSDC_OK:
    if (!check_obj (obj)) {
      warn ("** GET: checksum on object failed: %d\n", k);
    } else {
      aout << strbuf ("GET: %d -> %s\n", 
		      k, key_to_str (obj->checksum).cstr ());
    }
    break;
  case DSDC_RPC_ERROR:
    { 
       str s = cli->which_slave (k);
       if (!s) s = "<none>";
       warn << "** GET: RPC Error: " << s << "\n";
    }
    break;
  default:
    warn << "** GET: DSDC error " << status << "\n";
  }
  cb_done ();
}

static void
remove_cb (tst_key_t k, int status)
{
  switch (status) {
  case DSDC_NOTFOUND:
    aout << strbuf ("REMOVE: %d -> <null> (NOT FOUND)\n", k);
    break;
  case DSDC_OK:
    aout << strbuf ("REMOVED: %d\n", k);
    break;
  case DSDC_RPC_ERROR:
    warn << "** REMOVE: RPC error\n";
    break;
  default:
    warn << "** REMOVE: DSDC error " << status << "\n";
  }
  cb_done ();
}
static void
acquire_cb (tst_key_t k, ptr<dsdc_lock_acquire_res_t> res)
{
  switch (res->status) {
  case DSDC_OK:
    aout << strbuf ("LOCK ACQUIRED: %d -> %" PRIx64 "\n", k, *res->lockid);
    break;
  case DSDC_RPC_ERROR:
    warn << "** LOCK_ACQUIRE: RPC error\n";
    break;
  default:
    warn << "** LOCK_ACQUIRE: DSDC error " << res->status << "\n";
  }
    
  cb_done ();
}

static void
get (tst_key_t k, bool safe, int annt = -1)
{
  tst2_cbct++;

  annotation_t *a = NULL;
  if (annt >= 0) 
    a = dsdc::annotation::collector.int_alloc (annt);
    
  cli->get (k, wrap (get_cb, k), safe, a);
}

static void
remove (tst_key_t k, bool safe)
{
  tst2_cbct++;
  cli->remove (k, wrap (remove_cb, k), safe);
}

static void
release_cb (tst_key_t key, dsdcl_id_t lockid, int status)
{
  switch (status) {
  case DSDC_NOTFOUND:
    aout << strbuf ("LOCK_RELEASE: (%d, %" PRIx64 ") not found\n", key, lockid);
    break;
  case DSDC_RPC_ERROR:
    warn << "** LOCK_RELEASE: RPC error\n";
    break;
  case DSDC_OK:
    aout << strbuf ("LOCK_RELEASED: (%d, %" PRIx64 ")\n", key, lockid);
    break;
  default:
    warn << "** LOCK_RELEASE: DSDC error " << status << "\n";
    break;
  }
  cb_done ();

}

static void
release (tst_key_t key, dsdcl_id_t lockid, bool safe)
{
  tst2_cbct++;
  cli->lock_release (key, lockid, wrap (release_cb, key, lockid), safe);
}


static void
acquire (tst_key_t k, u_int to, bool shared, bool block, bool safe)
{
  tst2_cbct++;
  cli->lock_acquire (k, wrap (acquire_cb, k), to, !shared, block, safe);
}

static void
mget_cb (ptr<dsdc_mget_res_t> res)
{
  cb_done ();
}

static void
mget (ptr<vec<dsdc_key_t> > keys, bool safe)
{
  tst2_cbct++;
  sc->mget (keys, wrap (mget_cb));
}

static bool
do_mget (vec<str> &args, bool safe)
{
  tst_key_t key;
  ptr<vec<dsdc_key_t> > kvec = New refcounted<vec<dsdc_key_t> > ();
  for (u_int i = 1; i < args.size (); i++) {
    if (!convertint (args[i], &key))
      return false;
    mkkey (&((*kvec)[i-i]), key);
  }
  mget (kvec, safe);
  return true;
}

static bool
do_acquire (const vec<str> &args, bool safe)
{
  if (args.size () < 2 || args.size () > 5)
    return false;
  tst_key_t key = 0;
  u_int timeout = 0;
  bool shared = false;
  bool block = true;
  if (!convertint (args[1], &key))
    return false;
  if (args.size () > 2 && !convertint (args[2], &timeout))
    return false;

  if (args.size () > 3) {
    for (const char *cp = args[3].cstr (); *cp; cp++) {
      switch (*cp) {
      case 's':
	shared = true;
	break;
      case 'B':
	block = false;
	break;
      default:
	warn ("Unexepcted option to do_acquire: %c\n", *cp);
	break;
      }
    }
  }
  acquire (key, timeout, shared, block, safe);
  return true;

}


static void
rdline (str ln, int err)
{
  static rxx splrxx ("\\s+");
  vec<str> args;

  static rxx lnrx ("([pgrd])(-?)\\s+([0-9]+)?(\\s+([a-zA-Z0-9_-]+))?");
  char com;
  bool safe = false;
  str val;
  tst_key_t key = 0;

  if (err)
    fatal << "Readline error: " << err << "\n";
  if (!ln || ln == ".") {
    tst2_exit ();
    return;
  }
  if (!split (&args, splrxx, ln))
    goto done;

  if (args.size () < 1)
    goto done;

  com = args[0][0];
  if (args[0].len () == 2) {
    if (args[0][1] == '-')
      safe = true;
    else
      goto done;
  } else if (args[0].len () != 1)
    goto done;

  if (lnrx[3] && !convertint (lnrx[3], &key)) 
    goto done;

  val = lnrx[4];

  switch (com) {
  case 'p': 
    if (args.size () == 3 && convertint (args[1], &key)) {
      val = args[2];
      put (key, val, safe);
    }
    break;
  case 'r':
    {
      bool ok = true;
      int annt = -1;
      if (args.size () == 2) 
	ok = convertint (args.pop_back (), &annt);
      
      if (ok && args.size () == 1) {
	generate_kv (&key, &val);
	put (key, val, safe, annt);
      }
    }
    break;
  case 'g':
    {
      bool ok = true;
      int annt = -1;
      if (args.size () == 3)
	ok = convertint (args.pop_back (), &annt);
	
      if (ok && args.size () == 2 && convertint (args[1], &key))
	get (key, safe, annt);
    }
    break;
  case 'd':
    if (args.size () == 2 && convertint (args[1], &key))
      remove (key, safe);
    break;
  case 'a':
    do_acquire (args, safe);
    break;
  case 'm':
    do_mget (args, safe);
    break;
  case 'R':
    {
      dsdcl_id_t lockid;
      if (args.size () == 3 && convertint (args[1], &key) && 
	  convertint (args[2], &lockid)) {
	release (key, lockid, safe);
      }
      break;
    }
  default:
    break;
  }

 done:
  srdline ();
  return;
}

void
srdline ()
{
  if (!tst2_done)
    ain->readline (wrap (&rdline));
}

static void
main2 (bool b)
{
  if (!b) 
    warn << "all master connections failed\n";
  srdline ();
}

int
main (int argc, char *argv[])
{
  tst2_done = false;
  tst2_cbct = 0;
  int ch;
  int dbg_lev = 0;

  setprogname (argv[0]);

  sc = New dsdc_smartcli_t (DSDC_RETRY_ON_STARTUP);

  while ((ch = getopt (argc, argv, "d")) != -1)
    switch (ch) {
    case 'd':
      dbg_lev ++;
      break;
    default:
      usage ();
      break;
    }

  set_debug (dbg_lev);

  for (int i = optind; i < argc; i++) {
    str host = "localhost";
    int port = dsdc_port;
    if (!parse_hn (argv[i], &host, &port))
      usage ();
    sc->add_master (host, port);
  }
  cli = sc->make_interface<tst_key_t, tst_obj_checked_t> ();
  sc->init (wrap (main2));
  amain ();
}


