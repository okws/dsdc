
// -*-c++-*-

#include "fscache.h"
#include "fslru.h"
#include <stdlib.h>
#include "parseopt.h"

typedef rpc_str<0x10000> my_str_t;

tamed static void
main2 (fscache::cfg_t *cfg)
{
    tvars {
        holdvar fscache::engine_t fsc (cfg);
        fscache::lru_t<u_int64_t, my_str_t> l ("foos", &fsc, 60, 1);
        my_str_t s, s2;
        int rc;
        u_int64_t k (0x100);
        ptr<my_str_t> sp, sp2, sp3, sp5, sp6;
        int i, j;
        int rc2, rc3, rc4;
    }

    // make 1 trip through the select loop
    twait { delaycb (0, 0, mkevent ()); }

    for (i = 0 ; i < 10; i++, k+= 3) {
        {
            strbuf b;
            b << "hello-world--" << k << "." << i << "." << k;
            s = b;
        }
        twait { l.insert (k, s, mkevent (rc)); }
        warn ("insert: %" PRIx64 " -> %s : rc=%d\n", k, s.cstr (), rc);
    }

    k = 0x100;
    for (i = 0; i < 10; i++, k+= 3) {

        for (j = 0; j < 2; j++) {
            twait { l.get (k, mkevent (sp)); }
            if (!sp) {
                warn ("get failed (key=%" PRIx64 ")\n", k);
            } else {
                warn ("get: %" PRIx64 " -> %s\n", k, sp->cstr ());
            }
        }
    }

    warn << "Phase 2...\n";

    k = 0x103;
    twait {
        s = "blah blah blah blah";
        l.insert (k, s, mkevent (rc));
        l.get (k, mkevent (sp));
        l.remove (k, mkevent (rc2));
        l.get (k, mkevent (sp2));
    }

    assert (rc == 0);
    assert (sp && *sp == s);
    assert (rc2 == 0);
    assert (!sp2);

    warn << "Phase 3...\n";

    twait {
        l.get (k, mkevent (sp));
        l.insert (k, s, mkevent (rc));
        s2 = "foo foo foo foo";
        l.insert (k, s2, mkevent (rc2));
        l.get (k, mkevent (sp2));

        // do 2 get's to try to force k's lru entry out
        l.get (k + 3, mkevent (sp5));
        l.get (k + 6, mkevent (sp6));

        l.insert (k, s, mkevent (rc3));
        l.remove (k, mkevent (rc4));
        l.get (k, mkevent (sp3));
    }

    assert (!sp);
    assert (rc == 0);
    assert (rc2 == 0);
    assert (*sp2 == s2);
    assert (rc3 == 0);
    assert (rc4 == 0);
    assert (!sp3);

    assert (sp5);
    assert (sp6);

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
