
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

bool tst2_done = true;

/*
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

static bool
parse_kv (const str &in, tst_key_t *k, str *v)
{
  static rxx x ("([0-9]+),([0-9a-zA-Z_-]+)");
  if (!x.match (in))
    return false;
  if (!convertint (x[1], k))
    return false;
  *v = x[2];
  return true;
}

*/

static void
usage ()
{
  warn << "usage: " << progname << " m1:p1 m2:p2 m3:p3 ...\n";
  exit (1);
}

static void
rdline (dsdc_smartcli_t *sc, str ln, int err)
{
  // parse line and do an action

}

static void
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


