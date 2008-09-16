
// -*-c++-*-
/* $Id$ */

#include "dsdc_admin.h"
#include "dsdc_util.h"
#include "parseopt.h"
#include "dsdc_signal.h"
#include "dsdc_const.h"

int columns;

enum dsdc_adminmode_t {
  NONE = 0,
  STATS = 1,
  CLEAN = 2,
};

static void 
usage ()
{
  warnx << "usage: " << progname << " -S [-c<n-columns>] "
	<< "[-l<nbuck>] [-g<nbuck>] [-s<nbuck>] [-f<fmt>|-a] "
	<< "[-m<master>] [-b<stats-mode>] slave1 slave2 ...\n";
  exit (2);
}

tamed static void
connect (str s, callback<void, ptr<aclnt> >::ref cb)
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
      ptr<axprt> x = axprt_stream::alloc (fd);
      ret = aclnt::alloc (x, dsdc_prog_1);
    }
  }
  DSDC_SIGNAL (cb, ret);
}

tamed static void
get_stats (str m, const dsdc_get_stats_arg_t *arg, cbi cb)
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
  DSDC_SIGNAL (cb, rc);
}

tamed static void
get_stat_direct (str h, const dsdc_get_stats_single_arg_t *a, int *rc, cbv cb)
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
  DSDC_SIGNAL (cb);

}

//
// XXX try to fold this in with previous function, so only have to do it
// once.
//
tamed static void
set_stats_mode_single (str h, bool mode, int *rc, cbv cb)
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
  DSDC_SIGNAL (cb);
}

//
// XXX try to fold this in with get_stats_direct, so only have to do it
// once.
//
tamed static void
set_stats_mode (const vec<str> *s, int mode, cbi cb)
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
  DSDC_SIGNAL (cb, rc);
}

tamed static void
get_stats_direct (const vec<str> *s, const dsdc_get_stats_single_arg_t *a, 
		  cbi cb)
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
  DSDC_SIGNAL (cb, rc);
}


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
  while ((ch = getopt (argc, argv, "ab:f:c:l:g:s:ASRm:")) != -1) {
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
