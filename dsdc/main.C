
//
// $Id$
//

#include "parseopt.h"
#include "dsdc.h"
#include "dsdc_slave.h"
#include "dsdc_master.h"
#include "rxx.h"

class dsdc_run_t {
public:
  dsdc_run_t () : _app (NULL) {}
  dsdc_app_t *_app;
};

static void 
usage ()
{
  warnx << "usage: " << progname << " -M [-d] [-P <packetsz>] [-p <port>]\n"
	<< "       " << progname << " -S [-d] [-P <packetsz>] [-n <n nodes>] "
	<< "[-s <maxsize> (M|G|k|b)]  m1:p1 m2:p2 ...\n";
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

  while ((ch = getopt (argc, argv, "dMSp:n:s:h:P:")) != -1) {
    switch (ch) {
    case 'M':
      if (mode != DSDC_MODE_NONE)
	usage ();
      mode = DSDC_MODE_MASTER;
      break;
    case 'S':
      if (mode != DSDC_MODE_NONE)
	usage ();
      mode = DSDC_MODE_SLAVE;
      break;
    case 'p':
      if (!convertint (optarg, &port))
	usage ();
      break;
    case 'n':
      if (!convertint (optarg, &nnodes))
	usage ();
      break;
    case 's':
      if (!parse_memsize (optarg, 'm', &maxsz))
	usage ();
      break;
    case 'h':
      hostname = optarg;
      break;
    case 'd':
      dbg_lev ++;
      break;
    case 'P':
      if (!convertint (optarg, &dsdc_packet_sz))
	usage ();
      break;
    default:
      usage ();
      break;
    }
  }
  
  set_debug (dbg_lev);

  bool ret = true;
  switch (mode) {
  case DSDC_MODE_SLAVE:
    {
      dsdc_slave_t *s;
      if (!maxsz)
	maxsz = dsdc_slave_maxsz;
      if (!nnodes)
	nnodes = dsdc_slave_nnodes;
      if (port == -1)
	port = dsdc_slave_port;
      if (show_debug (1)) {
	warn ("starting slave with nnodes=%d and maxsz=0x%x\n", 
	      nnodes, maxsz);
      }
      s = New dsdc_slave_t (nnodes, maxsz, port);
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
      if (maxsz != 0) {
	warn << "-s <maxsz> can only be used in slave mode\n";
	usage ();
      }
      if (nnodes != 0) {
	warn << "-n <nnodes> can only be used in slave mode\n";
	usage ();
      }
      m = New dsdc_master_t (port);
      *app = m;
    }
    break;
  default:
    warn << "must supply either -M or -S option for master or slave\n";
    usage ();
  }

  set_hostname (hostname);
  if (!dsdc_hostname)
    ret = false;

  return ret;
}

int
main (int argc, char *argv[])
{
  setprogname (argv[0]);
  dsdc_app_t *app;
  if (!parseargs (argc, argv, &app))
    return -1;
  if (!app->init ())
    return -1;

  if (show_debug (1)) {
    str sm = app->startup_msg ();
    warn << "starting up (pid " << getpid () << ")";
    if (sm)
      warnx << ": " << sm ;
    warnx << "\n";
  }

  
  amain ();
  return 0;
}
