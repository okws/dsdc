
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
	my_str_t s ("foo");
    }

    l.insert (0x10, s);

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
