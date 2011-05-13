// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-
/* $Id$ */
//-----------------------------------------------------------------------

#include "dsdc_admin.h"
#include "dsdc_util.h"
#include "parseopt.h"
#include "dsdc_signal.h"
#include "dsdc_const.h"

int columns;

//-----------------------------------------------------------------------

enum dsdc_adminmode_t {
    NONE = 0,
    STATS = 1,
    CLEAN = 2,
    LIST = 3
};

//-----------------------------------------------------------------------

static void
usage ()
{
    warnx << "usage: " << progname << " -S [-c<n-columns>] "
          << "[-l<nbuck>] [-g<nbuck>] [-s<nbuck>] [-f<fmt>|-a] "
          << "[-m<master>] [-b<stats-mode>] slave1 slave2 ...\n"
          << "   - for statistics collection (more documentation needed)\n"
          << "\n"
          << "  " << progname << " -L -m <master>\n"
          << "   - for dumping the active slaves\n";
    exit (2);
}

//-----------------------------------------------------------------------

tamed static void
connect (str s, event<ptr<aclnt> >::ref ev)
{
    tvars {
        int fd (-1);
        str hn ("127.0.0.1");
        int port (dsdc_port);
        ptr<aclnt> ret;
    }
    if (!parse_hn (s, &hn, &port)) {
        warn << "Cannot parse hostname/port: " << s << "\n";
    } else {
        twait { tcpconnect (hn, port, mkevent (fd)); }
        if (fd < 0) {
            warn << "Cannot connect to host: " << s << "\n";
        } else {
            ptr<axprt> x = axprt_stream::alloc (fd, dsdc_packet_sz);
            ret = aclnt::alloc (x, dsdc_prog_1);
        }
    }
    ev->trigger (ret);
}

//-----------------------------------------------------------------------

static void
dump_state (const dsdcx_state_t &state)
{
    vec<str> hold;
    strbuf out;
    for (size_t i = 0; i < state.slaves.size (); i++) {
        const dsdcx_slave_t &slave = state.slaves[i];
        strbuf b;
        b << slave.hostname << ":" << slave.port << "\t" << slave.keys.size ();
        str s = b;
        hold.push_back (s);
        out << s << "\n";
    }
    out.tosuio ()->output (1);
}

//-----------------------------------------------------------------------

tamed static void
get_list (str m, evi_t ev)
{
    tvars {
        ptr<aclnt> c;
        int rc (0);
        dsdc_key_t arg;
		dsdc_getstate_res_t	res;
        clnt_stat err;
    }
    twait { connect (m, mkevent (c)); }
    if (!c) { 
        rc = -1;
    } else {
        make_empty_checksum (&arg);
        twait { 
            RPC::dsdc_prog_1::dsdc_getstate (c, arg, &res, mkevent (err)); 
        }
        if (err) {
            warn << "RPC error with " << m << ": " << err << "\n";
            rc = -1;
        } else if (!res.needupdate) {
            warn << "Master reported no results!!!\n";
            rc = -1;
        } else {
            dump_state (*res.state);
        }
    }
    ev->trigger (rc);
}

//-----------------------------------------------------------------------

tamed static void
get_stats (str m, const dsdc_get_stats_arg_t *arg, evi_t ev)
{
    tvars {
        ptr<aclnt> c;
        int rc (0);
        dsdc_slave_statistics_t res;
        clnt_stat err;
    }
    twait { connect (m, mkevent (c)); }
    if (!c) {
        rc = -1;
    } else {
        twait { RPC::dsdc_prog_1::dsdc_get_stats (c, arg, &res, mkevent (err)); }
        if (err) {
            warn << "RPC failure for host " << m << ": " << err <<"\n";
            rc = -1;
        } else {
            tabbuf_t b (columns);
            for (size_t i = 0; i < res.size (); i++) {
                output_stats (b, res[i].host, res[i].stats);
            }
            make_sync (0);
            b.tosuio ()->output (0);
        }
    }
    ev->trigger (rc);
}

//-----------------------------------------------------------------------

tamed static void
get_stat_direct (str h, const dsdc_get_stats_single_arg_t *a, int *rc, evv_t ev)
{
    tvars {
        ptr<aclnt> c;
        dsdc_get_stats_single_res_t res;
        clnt_stat err;
    }
    twait { connect (h, mkevent (c)); }
    if (!c) {
        *rc = -1;
    } else {
        twait {
            RPC::dsdc_prog_1::dsdc_get_stats_single (c, a, &res, mkevent (err));
        }
        if (err) {
            warn << "RPC failure for host " << h << ": " << err << "\n";
            *rc = -1;
        } else {
            tabbuf_t b (columns);
            output_stats (b, h, res);
            make_sync (0);
            b.tosuio ()->output (0);
        }
    }
    ev->trigger ();
}

//-----------------------------------------------------------------------

//
// XXX try to fold this in with previous function, so only have to do it
// once.
//
tamed static void
set_stats_mode_single (str h, bool mode, int *rc, evv_t ev)
{
    tvars {
        ptr<aclnt> c;
        clnt_stat err;
    }
    twait { connect (h, mkevent (c)); }
    if (!c) {
        *rc = -1;
    } else {
        twait {
            RPC::dsdc_prog_1::dsdc_set_stats_mode (c, mode, mkevent (err));
        }
        if (err) {
            warn << "RPC failure for host " << h << ": " << err << "\n";
            *rc = -1;
        }
    }
    ev->trigger ();
}

//-----------------------------------------------------------------------

//
// XXX try to fold this in with get_stats_direct, so only have to do it
// once.
//
tamed static void
set_stats_mode (const vec<str> *s, int mode, evi_t ev)
{
    tvars {
        size_t i;
        int rc (0);
    }
    twait {
        for (i = 0; i < s->size (); i++) {
            set_stats_mode_single ((*s)[i], mode, &rc, mkevent ());
        }
    }
    ev->trigger (rc);
}

//-----------------------------------------------------------------------

tamed static void
get_stats_direct (const vec<str> *s, const dsdc_get_stats_single_arg_t *a,
                  evi_t ev)
{
    tvars {
        size_t i;
        int rc (0);
    }
    twait {
        for (i = 0; i < s->size (); i++) {
            get_stat_direct ((*s)[i], a, &rc, mkevent ());
        }
    }
    ev->trigger (rc);
}

//-----------------------------------------------------------------------


tamed static void
main2 (int argc, char **argv)
{
    tvars {
        int ch, rc (0);
        str master;
        dsdc_adminmode_t mode (NONE);
        vec<str> slaves;
        int i;
        dsdc_get_stats_arg_t arg;
        dsdc_get_stats_single_arg_t sarg;
        int stats_mode (-1);
    }

    columns = 78;

    arg.hosts.set_typ (DSDC_SET_FIRST);

    sarg.params.lifetime_n_buckets =
        sarg.params.gets_n_buckets =
            sarg.params.objsz_n_buckets = 5;

    setprogname (argv[0]);
    while ((ch = getopt (argc, argv, "ab:f:c:l:g:s:ALSRm:")) != -1) {
        switch (ch) {
        case 'a':
            output_opts.set_all_flags ();
            break;
        case 'b':
            if (!convertint (optarg, &stats_mode) || stats_mode < 0)
                usage ();
            break;
        case 'f':
            output_opts.parse_flags (optarg);
            break;
        case 'c':
            if (!convertint (optarg, &columns))
                usage ();
            break;
        case 'l':
            if (!convertint (optarg, &sarg.params.lifetime_n_buckets))
                usage ();
            break;
        case 'g':
            if (!convertint (optarg, &sarg.params.gets_n_buckets))
                usage ();
            break;
        case 's':
            if (!convertint (optarg, &sarg.params.objsz_n_buckets))
                usage ();
            break;
        case 'S':
            mode = STATS;
            break;
        case 'L':
            mode = LIST;
            break;
        case 'A':
            arg.hosts.set_typ (DSDC_SET_ALL);
            break;
        case 'm':
            master = optarg;
            break;
        case 'R':
            arg.hosts.set_typ (DSDC_SET_RANDOM);
            break;
        default:
            usage ();
            break;
        }
    }

    argc -= optind;
    argv += optind;

    if (master && argc > 0)
        arg.hosts.set_typ (DSDC_SET_SOME);

    for (i = 0; i < argc; i++) {
        if (master) {
            arg.hosts.some->push_back (argv[i]);
        } else {
            slaves.push_back (argv[i]);
        }
    }

    if (stats_mode >= 0) {

        // In this case, just set the stats flag on the remote slaves.
        if (slaves.size () == 0) {
            usage ();
        } else {
            twait { set_stats_mode (&slaves, stats_mode, mkevent (rc)); }
        }

    } else if (mode == STATS) {
        if (master) {
            arg.getparams = sarg;
            twait { get_stats (master, &arg, mkevent (rc)); }
        } else if (slaves.size () > 0) {
            twait { get_stats_direct (&slaves, &sarg, mkevent (rc)); }
        } else {
            usage ();
        }
    } else if (mode == LIST) {
        if (!master) {
            usage ();
        } else {
            twait { get_list (master, mkevent (rc)); }
        }
    }
    exit (rc);
}

int
main (int argc, char *argv[])
{
    main2 (argc, argv);
    amain ();
    return -1;
}
