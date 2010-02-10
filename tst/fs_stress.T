// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "fscache.h"
#include <stdlib.h>
#include "parseopt.h"
#include "prng.h"
#include "aios.h"
#include "rxx.h"

#ifndef __STDC_FORMAT_MACROS
# define __STDC_FORMAT_MACROS
#endif
#include <inttypes.h>

//-----------------------------------------------------------------------

typedef fscache::file_id_t file_id_t;


//-----------------------------------------------------------------------

file_id_t mkfid (u_int32_t id) 
{
    strbuf n ("file-%" PRIx32 , id);
    return fscache::file_id_t (n, id);
}

//-----------------------------------------------------------------------

class cmd_t {
public:
    cmd_t () : _op (OP_NONE) {}

    typedef enum { OP_NONE = 0,
                   OP_CREATE = 1,
                   OP_DELETE = 2,
                   OP_LOAD = 3,
                   OP_ERROR = 4 } op_t;
    
    static op_t str2cmd (str s);
    file_id_t filename () const { return mkfid (_args[0]); }

    enum { N_ARGS = 3 } ;
    bool parse (str s);
    static ptr<cmd_t> alloc (str s);
    op_t _op;
    vec<u_int32_t> _args;
};

//-----------------------------------------------------------------------

cmd_t::op_t
cmd_t::str2cmd (str s)
{
    op_t ret = OP_NONE;
    if (s.len ()) {
        switch (tolower (s[0])) {
        case 'c': ret = OP_CREATE; break;
        case 'd': ret = OP_DELETE; break;
        case 'l': ret = OP_LOAD; break;
        default: ret = OP_ERROR;
        }
    }
    return ret;
}

//-----------------------------------------------------------------------

ptr<cmd_t>
cmd_t::alloc (str s)
{
    ptr<cmd_t> ret;
    if (s) {
        ret = New refcounted<cmd_t> ();
        if (!ret->parse (s)) {
            ret = NULL;
        }
    }
    return ret;
}

//-----------------------------------------------------------------------

bool
cmd_t::parse (str s)
{
    assert (s);
    static rxx x ("\\s+");
    vec<str> v;
    split (&v, x, s);
    bool ret = false;
    bool convert_ok = true;
    

    if (v.size () == 0) {
        // EOF
    } else if (v.size () < 2) {
        warn << "XX need at least 2 args, but got '" << s << "'\n";
    } else if (v.size () > 4) {
        warn << "XX too many arguments in command: " << s << "\n";
    } else {
        _args.setsize (v.size () - 1);
        if ((_op = str2cmd (v[0])) == OP_NONE || _op == OP_ERROR) {
            warn << "XX bad command: " << v[0] << "\n";
        } else {
            for (size_t i = 1; i < v.size (); i++) {
                if (!convertint (v[i], &_args[i-1])) {
                    warn << "Could not convert to int: " << v[i] << "\n";
                    convert_ok = false;
                }
            }
            if (convert_ok) {
                ret = true;
            }
        }
    }
    return ret;
}

//-----------------------------------------------------------------------

class tester_t {
public:
    tester_t (fscache::cfg_t *cfg, int c, bool verbose)
        : _cfg (cfg), 
          _fsc (cfg),
          _concur (c),
          _rand_data_size (64 * 1024 * 1024),
          _min_filesz (128),
          _max_filesz (4 * 1024 * 1024),
          _filesz_range (_max_filesz - _min_filesz),
          _nfiles_low_watermark (100),
          _filename_len (20),
          _verbose (verbose) {}

    void run (CLOSURE);

private:
    void run1 (evv_t ev, CLOSURE);
    void initialize_random_area ();
    str rand_reuse_file () const;
    str random_data (u_int32_t uid) const;
    str random_filename () const;
    void do_cmd (ptr<cmd_t> cmd, evv_t ev);

    void do_create (ptr<cmd_t> cmd, evv_t ev, CLOSURE);
    void do_load (ptr<cmd_t> cmd, evv_t ev, CLOSURE);
    void do_delete (ptr<cmd_t> cmd, evv_t ev, CLOSURE);
    str fullpath (const file_id_t &fid) const;
    void get_next_cmd (bool *eof, event<ptr<cmd_t> >::ref ev, CLOSURE);
    void report (str op, file_id_t fid, int rc) const;


    fscache::cfg_t *_cfg;
    fscache::engine_t _fsc;
    size_t _concur;
    vec<str> _files;
    str _rand_data;
    size_t _rand_data_size;
    size_t _min_filesz, _max_filesz, _filesz_range;
    size_t _nfiles_low_watermark;
    size_t _filename_len;
    bool _verbose;
};

//-----------------------------------------------------------------------

str
tester_t::fullpath (const file_id_t &fid) const
{
    str s = fid.fullpath (_cfg->n_levels ());
    strbuf b ("%s (%" PRIu32 ")", s.cstr (), fid.get_index ());
    return b;
}

//-----------------------------------------------------------------------

str
tester_t::random_filename () const
{
    size_t offset = random_getword () % (_rand_data_size - _filename_len);
    return armor32 (_rand_data.cstr () + offset, _filename_len);
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
tester_t::get_next_cmd (bool *eof, event<ptr<cmd_t> >::ref ev)
{
    tvars {
        str line;
        int err;
        ptr<cmd_t> cmd;
    }
    twait { ain->readline (mkevent (line, err)); }
    if (err) { 
        *eof = true;
    } else if (!line || line == ".") {
        *eof = true;
    } else {
        cmd = cmd_t::alloc (line);
    }
    ev->trigger (cmd);
}

//-----------------------------------------------------------------------

void
tester_t::report (str op, file_id_t fid, int rc) const
{
    str s;
    if (rc != 0 || _verbose) {
        s = fullpath (fid);
    }

    if (rc != 0) {
        errno = -rc;
        warn ("XX %s on file '%s' failed: %m\n", op.cstr(), s.cstr ());
    }

    if (_verbose) {
        warn ("II %s on file '%s' -> %d\n", op.cstr (), s.cstr (), rc);
    }
}

//-----------------------------------------------------------------------

tamed void
tester_t::do_load (ptr<cmd_t> cmd, evv_t ev)
{
    tvars {
        file_id_t fid (cmd->filename ());
        time_t t;
        int rc;
        str dat;
    }

    twait { _fsc.load (fid, mkevent (rc, t, dat)); }
    report ("load", fid, rc);
    ev->trigger ();
}

//-----------------------------------------------------------------------

str
tester_t::random_data (u_int32_t id) const
{
    size_t len = id % _filesz_range + _min_filesz;
    size_t offset = id % (_rand_data_size - len);
    return str (_rand_data.cstr () + offset, len);
}

//-----------------------------------------------------------------------

tamed void
tester_t::do_delete (ptr<cmd_t> cmd, evv_t ev)
{
    tvars {
        file_id_t fid (cmd->filename ());
        int rc;
    }
    
    twait { _fsc.remove (fid, mkevent (rc)); }
    report ("delete", fid, rc);
    ev->trigger ();
}

//-----------------------------------------------------------------------

tamed void
tester_t::do_create (ptr<cmd_t> cmd, evv_t ev)
{
    tvars {
        file_id_t fid (cmd->filename ());
        time_t t (sfs_get_timenow ());
        int rc;
        str dat;
    }
    if (cmd->_args.size () < 2) {
        warn ("XX wrong number of args for create: %zu\n", cmd->_args.size ());
        rc = -EINVAL;
    } else {
        dat = random_data (cmd->_args[1]);
        twait { _fsc.store (fid, t, dat, mkevent (rc)); }
    }
    report ("store", fid, rc);
    ev->trigger ();
}

//-----------------------------------------------------------------------

void
tester_t::do_cmd (ptr<cmd_t> cmd, evv_t ev)
{
    switch (cmd->_op) {
    case cmd_t::OP_CREATE: do_create (cmd, ev); break;
    case cmd_t::OP_DELETE: do_delete (cmd, ev); break;
    case cmd_t::OP_LOAD:   do_load (cmd, ev); break;
    default: 
        {
            warn << "XX unhandled opcode\n";
            ev->trigger ();
        }
    }
}

//-----------------------------------------------------------------------

tamed void
tester_t::run ()
{
    tvars {
        rendezvous_t<> rv (__FILE__, __LINE__);
        size_t n_out (0);
        ptr<cmd_t> cmd;
        bool eof (false);
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
            twait { get_next_cmd (&eof, mkevent (cmd)); }

            if (cmd) {
               do_cmd (cmd, mkevent (rv)); 
               n_out++;
            }
        }
    }
    exit (0);
}

//-----------------------------------------------------------------------

static void
usage ()
{
    warn << "usage: " << progname << " [-tsdv] [-n<levels>] "
         << "[-N<threads>] [-c<concurrency>] <root>\n"
         << "\n"
         << "  OPTIONS:\n"
         << "     -d   set debug tracing\n"
         << "     -s   simple-fast backend\n"
         << "     -t   threaded backend\n"
         << "     -c   concurrency (default: 20)\n"
         << "     -v   verbose\n";
    
        exit (1);
}

//-----------------------------------------------------------------------

int
main (int argc, char *argv[])
{
    int ch;
    tester_t *tester;
    int concurrency = 20;
    bool verbose = false;

    setprogname (argv[0]);
    fscache::cfg_t cfg;

    cfg._n_levels = 2;
    cfg._n_aiods = 1;

    while ((ch = getopt (argc, argv, "tsdr:n:N:vc:")) != -1) {
        switch (ch) {
        case 's':
            cfg._backend = fscache::BACKEND_SIMPLE_FAST;
            break;
        case 't':
            cfg._backend = fscache::BACKEND_THREADS;
            break;
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
        case 'c':
            if (!convertint (optarg, &concurrency)) {
                warn << "bad -c argument: " << optarg << "\n";
                usage ();
            }
            break;
        case 'v':
            verbose = true;
            break;
        default:
            usage ();
            break;
        }
    }

    argc -= optind;
    argv += optind;

    if (argc != 1) {
        warn << "no arguments expected; got " << argc << "\n";
        usage ();
    }
    cfg._root = argv[0];
    
    tester = New tester_t (&cfg, concurrency, verbose);
    tester->run ();

    amain ();
}

//-----------------------------------------------------------------------
