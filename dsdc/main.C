
//
// $Id$
//

#include <sys/types.h>
#include <unistd.h>

#include "tame.h"
#include "parseopt.h"
#include "dsdc_util.h"
#include "dsdc_slave.h"
#include "dsdc_master.h"
#include "rxx.h"
#include "dsdc.h"

str cmd_pidfile("");

class dsdc_run_t {
public:
    dsdc_run_t () : _app (NULL) {}
    dsdc_app_t *_app;
};

static void
usage (bool err = true)
{
    if (err) warnx << "\n";

    warnx << "usage: " << progname << " -M [-d<debug-level>] "
    << "[-P <packetsz>] [-p <port>]\n"
    << "       " << progname << " -S [-d<debug-level>] [-RD] "
    << "[-a <intrvl>] [-P <packetsz>] [-n <n nodes>]\n"
    << "                 [-s <maxsize> (M|G|k|b)]  [-p<port>] "
    << "m1:p1 m2:p2 ...\n"
    << "       " << progname << " -L [-d<debug-level>] [-p<port>] "
    << "m1:p1 m2:p2 ...\n"
    << "\n"
    << "Summary:\n"
    << "\n"
    << "  Run dsdc in one of three modes: lock, master, or slave,\n"
    << "  by specifying one of the -L, -M or -S flags, respectively.\n"
    << "\n"
    << "  -L lock server:\n"
    << "\n"
    << "     Make this DSDC process run as a lock server, handling\n"
    << "     distributed requests for locks from clients and smart\n"
    << "     clients.\n"
    << "\n"
    <<"   -M master node:\n"
    << "\n"
    << "     Make this DSDC node run as a master node, meaning that it\n"
    << "     will watch all slaves, and accumulate uptime statistics\n"
    << "     for the ring, then pass those on to the slaves and to\n"
    << "     the smart clients.  This information is crucial, since\n"
    << "     it directs traffic toward the correct nodes.\n"
    << "\n"
    << "  -S slave node:\n"
    << "\n"
    << "     Make this DSDC node run as a slave node, meaning that it\n"
    << "     will be storing data.  Supply the names of the masters\n"
    << "     to connect to as arguments, in <host>:<port> format.\n"
    << "\n"
    << "    Sub-options:\n"
    << "\n"
    << "     -R  Don't randomize, use deterministic seeds. Everytime\n"
    << "         a slave node starts up on this machine, with this port\n"
    << "         it will take the same seeds.  This will minimize the\n"
    << "         costs of a slave going down then back up.\n"
    << "     -D  Don't delete data after a ring chagne.  Keep old,\n"
    << "         potentially stale data around.  Maximizes hit ratios\n"
    << "         while minimizing consistency.\n"
    << "     -a <interval>\n"
    << "         Collect statistics (v2), and dump output to log every\n"
    << "         <interval> seconds.\n"
    << "\n"
    << " Global Options:\n"
    << "\n"
    << "     -P <packet-size>   Specify the largest allowable AXPRT "
    << "packet size.\n"
    << "     -p <port>          Listen on the given port\n"
    << "     -d <debug-level>   Specify a debug level for "
    << "error reporting.\n"
    << "\n"
    << "Shortcuts:\n"
    << "\n"
    << "   If dsdc is hardlinked to with the hardlinks:\n"
    << "\n"
    << "      dsdc_lockserver -> dsdc\n"
    << "      dsdc_master -> dsdc\n"
    << "      dsdc_slave -> slave\n"
    << "\n"
    << "  it runs automatically in lockserver, master, or slave mode, "
    << "respectively.\n"
    << "\n"
    << "dsdc version " << DSDC_VERSION_STR << "; built "
    << __DATE__ << " " << __TIME__ << "\n"
    << "\n";

    exit (1);
}

static bool
parse_memsize (const str &in, char units, size_t *outp)
{
    ssize_t out = 0;
    static rxx x ("([0-9]+)([bB]|[kKmMgG][bB]?)?");
    if (!x.match (in))
        return false;
    if (x[2])
        units = tolower (x[2][0]);

    ssize_t tmp = 0;
    if (!convertint (x[1], &tmp))
        return false;
    out = tmp;
    switch (units) {
    case 'b':
        break;
    case 'k':
        out = out << 10;
        break;
    case 'm':
        out = out << 20;
        break;
    case 'g':
        out = out << 30;
        break;
    default:
        panic ("unexpected unit size!!");
    }
    *outp = out;
    return true;
}

static void
check_no_data_slave_args (size_t maxsz, u_int nnodes)
{
    if (maxsz != 0) {
        warn << "-s <maxsz> can only be used in slave mode\n";
        usage ();
    }
    if (nnodes != 0) {
        warn << "-n <nnodes> can only be used in slave mode\n";
        usage ();
    }
}

static bool
parseargs (int argc, char *argv[], dsdc_app_t **app)
{
    dsdc_mode_t mode = DSDC_MODE_NONE;
    dsdc_mode_t implicit_mode = DSDC_MODE_NONE;
    int ch;
    u_int nnodes = 0;
    size_t maxsz = 0;
    int port = -1;
    str hostname;
    int dbg_lev = 0;
    int dbg_opt = 0;
    bool daemon_mode = false;
    int opts = 0;
    int stats_interval = -1;

    while ((ch = getopt (argc, argv, "a:vd:h:LMn:p:P:qRSs:Z:D")) != -1) {
        switch (ch) {
        case 'a':
            if (!convertint (optarg, &stats_interval)) {
                warn << "optarg to -a must be an int\n";
                usage ();
            }
            break;
        case 'd':
            if (!convertint (optarg, &dbg_opt)) {
                warn << "optarg to -d must be an int\n";
                usage ();
            }
            if (dbg_opt == 0) {
                dbg_lev = 0;
            } else {
                dbg_lev |= dbg_opt;
            }
            break;
        case 'h':
            hostname = optarg;
            break;
        case 'v':
            warnx << "DSDC (Dirt-simple Distributed Cache)\n"
            << "  Version " DSDC_VERSION_STR "\n"
            << "  Compiled " __DATE__ " " __TIME__ "\n"
            << "  w/ sfslite, Version " SFSLITE_PATCHLEVEL_STR "\n";
            exit (0);
            break;
        case 'L':
            if (mode != DSDC_MODE_NONE) {
                warn << "run mode supplied more than once.\n";
                usage ();
            }
            mode = DSDC_MODE_LOCKSERVER;
            break;
        case 'M':
            if (mode != DSDC_MODE_NONE) {
                warn << "run mode supplied more than once.\n";
                usage ();
            }
            mode = DSDC_MODE_MASTER;
            break;
        case 'n':
            if (!convertint (optarg, &nnodes)) {
                warn << "optarg to -n must be type int.\n";
                usage ();
            }
            break;
        case 'p':
            if (!convertint (optarg, &port)) {
                warn << "optarg to -p must be type int.\n";
                usage ();
            }
            break;
        case 'P':
            if (!convertint (optarg, &dsdc_packet_sz)) {
                warn << "optarg to -P must be type int.\n";
                usage ();
            }
            break;
        case 'q':
            daemon_mode = true;
            break;
        case 'D':
            opts = opts | SLAVE_NO_CLEAN;
            break;
        case 'R':
            opts = opts | SLAVE_DETERMINISTIC_SEEDS;
            break;
        case 'S':
            if (mode != DSDC_MODE_NONE) {
                warn << "run mode supplied more than once.\n";
                usage ();
            }
            mode = DSDC_MODE_SLAVE;
            break;
        case 's':
            if (!parse_memsize (optarg, 'm', &maxsz)) {
                warn << "invalid memory size given to -m\n";
                usage ();
            }
            break;
        case 'Z':
            cmd_pidfile = optarg;
            break;
        default:
            usage (false);
            break;
        }
    }

    if (progname == "dsdc_slave") {
        implicit_mode = DSDC_MODE_SLAVE;
    } else if (progname == "dsdc_master") {
        implicit_mode = DSDC_MODE_MASTER;
    } else if (progname == "dsdc_lockserver") {
        implicit_mode = DSDC_MODE_LOCKSERVER;
    }

    if (implicit_mode != DSDC_MODE_NONE) {
        if (mode != DSDC_MODE_NONE && mode != implicit_mode) {
            warn << "Cannot use dsdc_slave->dsdc hard link and supply a "
            << "different operation mode.\n";
            usage ();
        }
        mode = implicit_mode;
    }

    set_debug (dbg_lev);
    *app = NULL;

    bool ret = true;

    if (mode == DSDC_MODE_NONE) {
        warn << "must supply either -L, -M or -S option for lockmgr, master "
        << "or slave\n";
        usage ();
    }

    switch (mode) {
    case DSDC_MODE_SLAVE:
    case DSDC_MODE_LOCKSERVER:
    {
        dsdc_slave_app_t *s;
        if (mode == DSDC_MODE_SLAVE) {
            if (!maxsz)
                maxsz = dsdc_slave_maxsz;
            if (!nnodes)
                nnodes = dsdc_slave_nnodes;
            if (port == -1)
                port = dsdc_slave_port;
            s = New dsdc_slave_t (nnodes, maxsz, port, opts);
        } else {
            check_no_data_slave_args (maxsz, nnodes);
            s = New dsdcs_lockserver_t (port, opts);
        }

        bool added = false;
        for (int i = optind; i < argc; i++) {
            str mhost = "localhost";
            int mport = dsdc_port;
            if (!parse_hn (argv[i], &mhost, &mport)) {
                warn << "bad master specification: " << argv[i] << "\n";
                ret = false;
            }
            s->add_master (mhost, mport);
            added = true;
        }

        if (!added)
            s->add_master ("localhost", dsdc_port);

        *app = s;
    }
    break;
    case DSDC_MODE_MASTER:
    {
        dsdc_master_t *m;
        m = New dsdc_master_t (port);
        *app = m;
    }
    break;
    default:
        break;
    }

    set_hostname (hostname);
    if (!dsdc_hostname)
        ret = false;

    if (*app) {
        (*app)->set_daemon_mode (daemon_mode);
        (*app)->set_stats_mode2 (stats_interval);
    }

    return ret;
}

static void
dsdc_abort ()
{
    panic ("Caught abort signal!\n");
}

static void
dsdc_exit_on_sig (int sig)
{
    if (show_debug (DSDC_DBG_LOW)) {
        warn ("Caught shutdown signal=%d\n", sig);
    }
    exit (0);
}


static void
set_signal_handlers ()
{
    sigcb (SIGTERM, wrap (dsdc_exit_on_sig, SIGTERM));
    sigcb (SIGINT,  wrap (dsdc_exit_on_sig, SIGINT));
    sigcb (SIGABRT, wrap (dsdc_abort));
}


int
main (int argc, char *argv[])
{
    setprogname (argv[0]);

    dsdc_app_t *app = NULL;

    set_signal_handlers ();

    if (!parseargs (argc, argv, &app))
        return -1;
    if (!app)
        return -1;

    if (!app->init ())
        return -1;

    str pidfile_name;
    if (cmd_pidfile.len() != 0) {
        pidfile_name = cmd_pidfile;
    } else {
        // With last arg = false, do not put pid into progname
        pidfile_name = app->progname (argv[0], false);
    }

    if (app->daemonize ())
        daemonize ();

    // With last arg = true, use the pid in the progname
    str pn = app->progname (argv[0], true);
    setprogname (const_cast<char *> (pn.cstr ()));

    if (app->daemonize () || show_debug (DSDC_DBG_LOW)) {
        str sm = app->startup_msg ();
        warn << "starting up";
        if (sm)
            warnx << ": " << sm ;
        warnx << "\n";
    }

    amain ();
    return 0;
}
