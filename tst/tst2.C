
#include "dsdc.h"
#include "tst_prot.h"
#include "async.h"
#include "crypt.h"
#include "parseopt.h"
#include "rxx.h"
#include "dsdc_prot.h"
#include "dsdc_const.h"
#include "aios.h"
#include "dsdc_smartcli.h"

typedef enum { NONE = 0,
	       GET = 1,
	       PUT = 2 } tst_mode_t;

bool tst2_done = false;
int tst2_cbct = 0; // callback count

static void
hash_key (const tst_key_t &in, dsdc_key_t *k)
{
  sha1_hashxdr (k->base (), in);
}

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
    aout << "GET: " << mapping << " (rc=" << res << ")\n";
  }
  cb_done ();
}

static void
put (dsdc_smartcli_t *sc, tst_key_t k, str v, bool safe)
{
  ptr<dsdc_put_arg_t> arg = New refcounted<dsdc_put_arg_t> ();
  hash_key (k, &arg->key);

  tst_obj_checked_t obj;
  obj.obj.key = k;
  obj.obj.val = v;

  compute_checksum (&obj);
  if (! xdr2bytes (arg->obj, obj)) {
    warn << "xdr2bytes failed\n";
    exit (1);
  }

  strbuf mapping ("%d (%s) -> %s", 
		  k,
		  key_to_str (arg->key).cstr (), 
		  key_to_str (obj.checksum).cstr ());
 
  tst2_cbct++;
  sc->put (arg, wrap (put_cb, str (mapping)), safe);
}

static void
get_cb (str k, ptr<dsdc_get_res_t> res)
{
  tst_obj_checked_t obj;
  switch (res->status) {
  case DSDC_NOTFOUND:
    aout << strbuf ("GET: %s -> <null> (NOT FOUND)\n", k.cstr ());
    break;
  case DSDC_OK:
    if (!bytes2xdr (obj, *res->obj)) {
      warn << "** GET: bytes2xdr failed!\n";
    } else if (!check_obj (&obj)) {
      warn ("** GET: checksum on object failed: %s\n", k.cstr ());
    } else {
      aout << strbuf ("GET: %s -> %s\n", 
		      k.cstr (), key_to_str (obj.checksum).cstr ());
    }
    break;
  case DSDC_RPC_ERROR:
    warn << "** GET: RPC error: " << *res->err << "\n";
    break;
  default:
    warn << "** GET: DSDC error " << res->status << "\n";
  }
  cb_done ();
}

static void
get (dsdc_smartcli_t *sc, tst_key_t k, bool safe)
{
  ptr<dsdc_key_t> outkey = New refcounted<dsdc_key_t> ();
  strbuf key_str ("%d (%s)", k, key_to_str (*outkey).cstr ());
  hash_key (k, outkey);
  sc->get (outkey,  wrap (get_cb, strbuf (key_str)), safe);
}

static void
remove (tst_key_t k, bool safe)
{

}


static void
rdline (dsdc_smartcli_t *sc, str ln, int err)
{
  static rxx lnrx ("([pgrd])(-?)\\s+([0-9]+)?(\\s+([a-zA-Z0-9_-]+))?");
  char com;
  bool safe;
  str val;
  tst_key_t key = 0;

  if (err)
    fatal << "Readline error: " << err << "\n";
  if (!ln || ln == ".") {
    tst2_exit ();
    return;
  }
  if (!lnrx.search (ln)) 
    goto done;

  com = lnrx[1].cstr () [0];
  safe = lnrx[2];

  if (lnrx[3] && !convertint (lnrx[3], &key)) 
    goto done;

  val = lnrx[4];

  switch (com) {
  case 'p': 
    if (key && val) 
      put (sc, key, val, safe);
    break;
  case 'r':
    generate_kv (&key, &val);
    put (sc, key, val, safe);
    break;
  case 'g':
    if (key)
      get (sc, key, safe);
    break;
  case 'd':
    if (key)
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


