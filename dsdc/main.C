
//
// $Id$
//

#include <sys/types.h>
#include <unistd.h>

#include "parseopt.h"
#include "dsdc_util.h"
#include "dsdc_slave.h"
#include "dsdc_master.h"
#include "rxx.h"

char *pidfile_name;

class dsdc_run_t {
public:
  dsdc_run_t () : _app (NULL) {}
  dsdc_app_t *_app;
};

static void
usage ()
{
  warnx << "usage: " << progname << " -M [-d] [-P <packetsz>] [-p <port>]\n"
	<< "       " << progname << " -S [-dR] [-P <packetsz>] [-n <n nodes>] "
	<< "[-s <maxsize> (M|G|k|b)]  m1:p1 m2:p2 ...\n"
	<< "       " << progname << " -L m1:p1 m2:p2 ...\n" ;
  exit (1);
}

static bool
parse_memsize (const str &in, char units, u_int32_t *outp)
{
  u_int32_t out;
  static rxx x ("([0-9]+)([bB]|[kKmMgG][bB]?)?");
  if (!x.match (in))
    return false;
  if (x[2]) 
    units = tolower (x[2][0]);

  if (!convertint (x[1], &out))
    return false;
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
  int ch;
  u_int nnodes = 0;
  u_int maxsz = 0;
  int port = -1;
  str hostname;
  int dbg_lev = 0;
  int dbg_opt;
  bool daemon_mode = false;
  int opts = 0;

  while ((ch = getopt (argc, argv, "d:h:LMn:p:P:qRSs:")) != -1) {
    switch (ch) {
    case 'd':
      if (!convertint (optarg, &dbg_opt)) {
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
    case 'L':
      if (mode != DSDC_MODE_NONE)
	usage ();
      mode = DSDC_MODE_LOCKSERVER;
      break;
    case 'M':
      if (mode != DSDC_MODE_NONE)
	usage ();
      mode = DSDC_MODE_MASTER;
      break;
    case 'n':
      if (!convertint (optarg, &nnodes))
	usage ();
      break;
    case 'p':
      if (!convertint (optarg, &port))
	usage ();
      break;
    case 'P':
      if (!convertint (optarg, &dsdc_packet_sz))
	usage ();
      break;
    case 'q':
      daemon_mode = true;
      break;
    case 'R':
      opts = opts | SLAVE_DETERMINISTIC_SEEDS;
      break;
    case 'S':
      if (mode != DSDC_MODE_NONE)
	usage ();
      mode = DSDC_MODE_SLAVE;
      break;
    case 's':
      if (!parse_memsize (optarg, 'm', &maxsz))
	usage ();
      break;
    default:
      usage ();
      break;
    }
  }

  set_debug (dbg_lev);
  *app = NULL;

  bool ret = true;
  switch (mode) {
  case DSDC_MODE_SLAVE:
      pidfile_name = "dsdc_slave";
      break;
  case DSDC_MODE_LOCKSERVER:
      pidfile_name = "dsdc_nlm";
      break;
  case DSDC_MODE_MASTER:
      pidfile_name = "dsdc_master";
      break;
  default:
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

  if (*app) 
    (*app)->set_daemon_mode (daemon_mode);

  return ret;
}

int
main (int argc, char *argv[])
{
  setprogname (argv[0]);

  dsdc_app_t *app = NULL;

  if (!parseargs (argc, argv, &app))
    return -1;
  if (!app)
    return -1;

  if (!app->init ())
    return -1;

#ifdef __FreeBSD__
  setproctitle ("%s", pidfile_name);
#endif /* __FreeBSD__ */
  setprogname (pidfile_name);

  if (app->daemonize ()) 
    daemonize ();
  // if this is a "const char *" somehow g++ omits the
  // call to setprogname().
  str pn = app->progname (argv[0]);
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

