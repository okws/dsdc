
// -*-c++-*-

#include "fscache.h"
#include "fslru.h"
#include <stdlib.h>
#include "parseopt.h"

typedef rpc_str<0x10000> my_str_t;

TAMED static void
main2 (fscache::cfg_t *cfg)
{
    VARS {
        holdvar fscache::engine_t fsc (cfg);
	fscache::lru_t<u_int64_t, my_str_t> l ("foos", &fsc, 60, 1);
	my_str_t s;
	int rc;
	u_int64_t k (0x100);
	ptr<my_str_t> sp;
	int i, j;
    }
    
    // make 1 trip through the select loop
    BLOCK { delaycb (0, 0, @()); }

    for (i = 0 ; i < 10; i++, k+= 3) {
      {
	strbuf b;
	b << "hello-world--" << k << "." << i << "." << k;
	s = b;
      }
      BLOCK { l.insert (k, s, @(rc)); }
      warn ("insert: %" PRIx64 " -> %s : rc=%d\n", k, s.cstr (), rc);
    }

    k = 0x100;
    for (i = 0; i < 10; i++, k+= 3) {
      
      for (j = 0; j < 2; j++) {
	BLOCK { l.get (k, @(sp)); }
	if (!sp) {
	  warn ("get failed (key=%" PRIx64 ")\n", k);
	} else {
	  warn ("get: %" PRIx64 " -> %s\n", k, sp->cstr ());
	}
      }
    }

    exit (0);
}

static void
usage ()
{
  warn << "usage: " << progname << " [-r<root>] [-n<levels>]\n";
  exit (1);
}

int
main (int argc, char *argv[])
{
    int ch;

    setprogname (argv[0]);
    fscache::cfg_t cfg;

    cfg._n_levels = 2;

    while ((ch = getopt (argc, argv, "r:n:cD")) != -1) {
        switch (ch) {
            case 'r':
                cfg._root = optarg;
                break;
            case 'n':
                if (!convertint (optarg, &cfg._n_levels))
                    usage ();
                break;
            default:
                usage ();
                break;
        }
    }

    argc -= optind;
    argv += optind;

    if (argc != 0)
        usage ();

    main2(&cfg);
    amain ();
}
