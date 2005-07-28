
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

typedef enum { NONE = 0,
	       GET = 1,
	       PUT = 2 } tst_mode_t;

bool tst2_done = false;
int tst2_cbct = 0; // callback count

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

  mstr m (40);
  int shift = 0;
  u_int32_t w;
  for (u_int i = 0 ; i < 40; i ++) {
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
  warn << "usage: " << progname << " m1:p1 m2:p2 m3:p3 ...\n";
  exit (1);
}

static void
tst2_exit ()
{
  if (!tst2_cbct)
    exit (0);
  tst2_done = true;
}

static void srdline (dsdc_smartcli_t *sc);

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
put (dsdc_smartcli_t *sc, tst_key_t k, str v, bool safe)
{
  tst_obj_checked_t obj;
  obj.obj.key = k;
  obj.obj.val = v;

  compute_checksum (&obj);

  // for debug purposes
  str tmp = key_to_str (obj.checksum);
  strbuf mapping ("%d -> %s", k, tmp.cstr ());
 
  tst2_cbct++;
  sc->put3 (k, obj, wrap (put_cb, str (mapping)), safe);
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
    warn << "** GET: RPC error\n";
    break;
  default:
    warn << "** GET: DSDC error " << status << "\n";
  }
  cb_done ();
}

static void
get (dsdc_smartcli_t *sc, tst_key_t k, bool safe)
{
  sc->Xtmpl get3<tst_key_t, tst_obj_checked_t> (k, wrap (get_cb, k), safe);
}

static void
remove (tst_key_t k, bool safe)
{

}


static void
rdline (dsdc_smartcli_t *sc, str ln, int err)
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
      put (sc, key, val, safe);
    }
    break;
  case 'r':
    if (args.size () == 1) {
      generate_kv (&key, &val);
      put (sc, key, val, safe);
    }
    break;
  case 'g':
    if (args.size () == 2 && convertint (args[1], &key))
      get (sc, key, safe);
    break;
  case 'd':
    if (args.size () == 2 && convertint (args[1], &key))
      remove (key, safe);
    break;
  default:
    break;
  }

 done:
  srdline (sc);
  return;
}

void
srdline (dsdc_smartcli_t *sc)
{
  if (!tst2_done)
    ain->readline (wrap (&rdline, sc));
}

static void
main2 (dsdc_smartcli_t *sc, bool b)
{
  if (!b) 
    fatal << "all master connections failed\n";
  srdline (sc);
}

int
main (int argc, char *argv[])
{
  tst2_done = false;
  tst2_cbct = 0;

  setprogname (argv[0]);

  dsdc_smartcli_t *sc = New dsdc_smartcli_t ();

  for (int i = 1; i < argc; i++) {
    str host = "localhost";
    int port = dsdc_port;
    if (!parse_hn (argv[i], &host, &port))
      usage ();
    sc->add_master (host, port);
  }
  sc->init (wrap (main2, sc));
  amain ();
}


