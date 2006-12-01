
// -*-c++-*-

#include "fscache.h"
#include <stdlib.h>
#include "parseopt.h"

TAMED static void
main2 (fscache::cfg_t *cfg, str name, int key, str fn)
{
    VARS {
        fscache::iface_t fsc (cfg);
        str fdat, fdat2;
        fscache::file_id_t id (name, key);
        time_t t, t2;
        int rc;
    }
    if (!(fdat = file2str (fn))) {
        warn << "Cannot open file: " << fn << "\n";
        exit (1);
    }
    warn << "File name is: '" << fsc.filename (id) << "'\n";
    t = time (NULL);
    BLOCK { fsc.store (id, t, fdat, @(rc)); }
    if (rc != 0) {
        warn << "Failed store command, error code: "  << rc << "\n";
        exit (1);
    }
    BLOCK { fsc.load (id, @(rc, t2, fdat2)); }
    if (rc != 0) {
        warn << "Failed load command, error code: " << rc << "\n";
        exit (1);
    }
    if (t != t2) {
        warn << "timestamp mismatch (" << t << " vs. " << t2 << ")\n";
    }
    if (fdat != fdat2) {
        warn << "data mismatch; files differ.\n";
    }

    BLOCK { fsc.remove (id, @(rc)); }
    if (rc != 0) {
        warn <<  "Failed removed command, error code: " << rc << "\n";
        exit (1);
    }

    BLOCK { fsc.load (id, @(rc, t2, fdat2)); }
    if (rc != -ENOENT) {
        warn << "Load after remove didn't fail as expected; rc=" << rc << "\n";
        exit (1);
    }
    exit (0);
}

static void
usage ()
{
    warn << "usage: " << progname << " [-r<root>] [-n<levels>] "
         << " <name> <key> <file>\n";
    exit (1);
}

int
main (int argc, char *argv[])
{
    int ch;

    str name;
    int key;
    str file;

    setprogname (argv[0]);
    fscache::cfg_t cfg;

    while ((ch = getopt (argc, argv, "r:n:")) != -1) {
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

    if (argc != 3)
        usage ();

    name = argv[0];
    if (!convertint (argv[1], &key))
        usage ();
    file = argv[2];

    main2(&cfg, name, key, file);
    amain ();
}
