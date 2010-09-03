// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "fscache.h"
#include <stdlib.h>
#include "parseopt.h"

enum { OPT_CORRUPT = 0x1,
       OPT_NO_DELETE = 0x2
     };

tamed static void
main2 (fscache::cfg_t *cfg, str name, u_int32_t key, str fn, int opts)
{
    tvars {
        fscache::engine_t fsc (cfg);
        str fdat, fdat2;
        fscache::file_id_t id (name, key);
        time_t t, t2;
        int rc;
        str ffn;
    }

    if (!fsc.init ()) {
      warn << "failed to initialize the backend FS-engine!\n";
      exit (1);
    }

    if (!(fdat = file2str (fn))) {
        warn << "Cannot open file: " << fn << "\n";
        exit (1);
    }

    ffn = fsc.filename (id);
    warn << "File name is: '" << ffn << "'\n";
    t = time (NULL);
    twait { fsc.store (id, t, fdat, mkevent (rc)); }
    if (rc != 0) {
        warn << "Failed store command, error code: "  << rc << "\n";
        exit (1);
    }
    if (opts & OPT_CORRUPT) {
        int fd = open (ffn.cstr(), O_WRONLY);
        if (fd < 0) {
            warn << "Cannot open file '" << ffn << "' for corruption\n";
        } else {
            const char *s = "XX";
            lseek (fd, 0x100, SEEK_SET);
            if (write (fd, s, strlen (s)) < 0) {
                warn << "Write to file for corruption failed.\n";
            }
            close (fd);
        }
    }


    twait { fsc.load (id, mkevent (rc, t2, fdat2)); }
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

    if (!(opts & OPT_NO_DELETE)) {

        twait { fsc.remove (id, mkevent (rc)); }
        if (rc != 0) {
            warn <<  "Failed removed command, error code: " << rc << "\n";
            exit (1);
        }
        twait { fsc.load (id, mkevent (rc, t2, fdat2)); }
        if (rc != -ENOENT) {
            warn << "Load after remove didn't fail as expected; rc=" 
                 << rc << "\n";
            exit (1);
        }
    }
    exit (0);
}

static void
usage ()
{
    warn << "usage: " << progname << " [-tsDc] [-r<root>] [-n<levels>] "
         << "[-N<threads>] <name> <key> <file>\n"
         << "\n"
         << "  OPTIONS:\n"
         << "     -d   set debug tracing\n"
         << "     -s   simple-fast backend\n"
         << "     -t   threaded backend\n"
         << "     -D   don't delete the file\n"
         << "     -c   corrupt the file\n";
    exit (1);
}

int
main (int argc, char *argv[])
{
    int ch;

    str name;
    u_int32_t key = 0;
    str file;

    int opts = 0;

    setprogname (argv[0]);
    fscache::cfg_t cfg;

    cfg._n_levels = 2;

    while ((ch = getopt (argc, argv, "tsr:n:cDdN:")) != -1) {
        switch (ch) {
        case 's':
            cfg._backend = fscache::BACKEND_SIMPLE_FAST;
            break;
        case 't':
            cfg._backend = fscache::BACKEND_THREADS;
            break;
        case 'c':
            opts |= OPT_CORRUPT;
            break;
        case 'D':
            opts |= OPT_NO_DELETE;
            break;
        case 'r':
            cfg._root = optarg;
            break;
        case 'n':
            if (!convertint (optarg, &cfg._n_levels))
                usage ();
            break;
        case 'N':
            if (!convertint (optarg, &cfg._n_aiods))
                usage ();
            break;
        case 'd':
            cfg.set_debug_flag (fscache::DEBUG_OP_TRACE);
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

    main2(&cfg, name, key, file, opts);
    amain ();
}
