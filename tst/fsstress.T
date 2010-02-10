// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "fscache.h"
#include <stdlib.h>
#include "parseopt.h"
#include "prng.h"

//-----------------------------------------------------------------------

file_id_t mkfid (str s) 
{
    return fscache::file_id_t (s, (hash_t )s);
}

//-----------------------------------------------------------------------

class tester_t {
public:
    tester_t (fscache::cfg_t *cfg, int c)
        : _cfg (cfg), 
          _engine (cfg),
          _concur (c),
          _rand_data_size (256 * 1024 * 1024),
          _min_filesz (128),
          _max_filesz (_rand_data_size >> 3),
          _p_resue (.1),
          _p_unlink (.1),
          _nfiles_low_watermark (100),
          _filename_len (20) 

    void run (CLOSURE);

private:
    void run1 (evv_t ev, CLOSURE);
    void initialize_random_area ();
    str rand_reuse_file () const;
    str random_data () const;
    str random_filename () const;


    fscache::cfg_t *_cfg;
    fscache::engine_t _fsc;
    size_t _concur;
    vec<str> _files;
    str _rand_data;
    size_t _rand_data_size;
    size_t _nfile_low_watermark;
    size_t _filename_len;

    double _p_resue, _p_unlink;
};

//-----------------------------------------------------------------------

str
tester_t::random_filename () const
{
    size_t offset = random_getword () % (_rand_data_size - _filename_len);
    return armor32 (_rand_data_size.cstr () + offset, _filename_len);
}

//-----------------------------------------------------------------------

void
tester_t::initialize_random_area ()
{
    warn << "+ initializing " << _rand_data_size << " bytes of random data\n";
    mstr dat (_rand_data_size);
    rnd.getbytes (dat.cstr (), _rand_data_size);
    _rand_data = dat;
    warn << "- done!\n";
}

//-----------------------------------------------------------------------

tamed void
tester_t::run1 (evv_t ev)
{
    tvars {
        str f;
    }
    if ((f = rand_resue_file ())) {
        twait { do_file (f, true, mkevent ()); }
    } else {
        twait { do_new_file (mkevent ()); }
    }
    ev->trigger ();
}

//-----------------------------------------------------------------------

tamed void
tester_t::run ()
{
    tvars {
        rendezvous<void> rv (__FILE__, __LINE__);
        size_t n_out (0);
        bool go;
        ptr<cmd_t> cmd;
    }

    if (!_fsc.init ()) {
        warn << "failed to initialize fscache engine\n";
        exit (0);
    }

    initialize_random_area ();

    while (!eof || n_out > _concur) {
        if (n_out > _concur || eof) {
            twait (rv);
            n_out--;
        } else {
            twait { get_next_cmd (mkevent (cmd)); }

            if (!cmd) { 
                eof = false; 
            } else { 
               do_cmd (cmd, mkevent (rv)); 
               n_out++;
            }
        }
    }
    exit (0);
}

//-----------------------------------------------------------------------


tamed static void
run (fscache::cfg_t *cfg, int iters)
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

    twait { fsc.remove (id, mkevent (rc)); }
    if (rc != 0) {
        warn <<  "Failed removed command, error code: " << rc << "\n";
        exit (1);
    }

    twait { fsc.load (id, mkevent (rc, t2, fdat2)); }
    if (rc != -ENOENT) {
        warn << "Load after remove didn't fail as expected; rc=" << rc << "\n";
        exit (1);
    }
    exit (0);
}

//-----------------------------------------------------------------------

static void
usage ()
{
    warn << "usage: " << progname << " [-tsd] [-r<root>] [-n<levels>] "
         << "[-N<threads>] [-i<iters>] [-c<concurrency>]\n"
         << "\n"
         << "  OPTIONS:\n"
         << "     -d   set debug tracing\n"
         << "     -s   simple-fast backend\n"
         << "     -t   threaded backend\n"
         << "     -i   iterations to run (default: 1000)\n"
         << "     -c   concurrency (default: 20)\n"
    
    exit (1);
}

//-----------------------------------------------------------------------

int
main (int argc, char *argv[])
{
    int ch;
    int iters = 1000;
    tester_t *tester;
    int concurrency = 20;

    setprogname (argv[0]);
    fscache::cfg_t cfg;

    cfg._n_levels = 2;

    while ((ch = getopt (argc, argv, "tsdr:n:N:i:")) != -1) {
        switch (ch) {
        case 's':
            cfg._backend = fscache::BACKEND_SIMPLE_FAST;
            break;
        case 't':
            cfg._backend = fscache::BACKEND_THREADS;
            break;
        case 'r':
            cfg._root = optarg;
            break;
        case 'n':
            if (!convertint (optarg, &cfg._n_levels)) {
                warn << "bad -n argument: " << optarg << "\n";
                usage ();
            }
            break;
        case 'N':
            if (!convertint (optarg, &cfg._n_aiods)) {
                warn << "bad -N argument: " << optarg << "\n";
                usage ();
            }
            break;
        case 'd':
            cfg.set_debug_flag (fscache::DEBUG_OP_TRACE);
            break;
        case 'i':
            if (!convertint (optarg, &iters)) {
                warn << "bad -i argument: " << optarg << "\n";
                usage ();
            }
            break;
        case 'c':
            if (!convertint (optarg, &concurrency)) {
                warn << "bad -c argument: " << optarg << "\n";
                usage ();
            }
        default:
            usage ();
            break;
        }
    }

    argc -= optind;
    argv += optind;

    if (argc != 0) {
        warn << "no arguments expected; got " << argc << "\n";
        usage ();
    }
    
    tester = New tester_t (&cfg, iters, concurrency);
    tester->run ();

    amain ();
}

//-----------------------------------------------------------------------
