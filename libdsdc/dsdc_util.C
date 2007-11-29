
#include "dsdc_util.h"
#include "async.h"
#include "rxx.h"
#include "parseopt.h"

namespace dsdc {

uint32_t frobber(str s) {
	if (s == "MATCHD_FRONTD_FROBBER") {
        return MATCHD_FRONTD_FROBBER;
    } else if (s == "MATCHD_FRONTD_USERCACHE_FROBBER") {
        return MATCHD_FRONTD_USERCACHE_FROBBER;
    } else if (s == "UBER_USER_FROBBER") {
        return UBER_USER_FROBBER;
    } else if (s == "PROFILE_STALKER_FROBBER") {
        return PROFILE_STALKER_FROBBER;
    } else if (s == "MATCHD_FRONTD_MATCHCACHE_FROBBER") {
        return MATCHD_FRONTD_MATCHCACHE_FROBBER;
    } else if (s == "GROUP_INFO_FROBBER") {
        return GROUP_INFO_FROBBER;
    } else if (s == "GTEST_SCORE_FROBBER") {
        return GTEST_SCORE_FROBBER;
    } else if (s == "PTEST_SCORE_FROBBER") {
        return PTEST_SCORE_FROBBER;
    } else if (s == "MTEST_SCORE_FROBBER") {
        return MTEST_SCORE_FROBBER;
    } else if (s == "CUPID_TEST_SCORE_FROBBER") {
        return CUPID_TEST_SCORE_FROBBER;
    } else if (s == "GTEST_SESSION_FROBBER") {
        return GTEST_SESSION_FROBBER;
    } else if (s == "PTEST_SESSION_FROBBER") {
        return PTEST_SESSION_FROBBER;
    } else if (s == "MTEST_SESSION_FROBBER") {
        return MTEST_SESSION_FROBBER;
    } else if (s == "MTEST_METADATA_FROBBER") {
        return MTEST_METADATA_FROBBER;
    } else if (s == "MTEST_STATS_FROBBER") {
        return MTEST_STATS_FROBBER;
    } else if (s == "SETTINGS_FROBBER") {
        return SETTINGS_FROBBER;
    } else if (s == "PROFILE_FUZZY_MATCHES_FROBBER") {
        return PROFILE_FUZZY_MATCHES_FROBBER;
    } else if (s == "AD_KEYWORD_FROBBER") {
        return AD_KEYWORD_FROBBER;
    }
    // the next frobber is 18
    else if (s == "USER_LANG_FROBBER") {
        return 18;
    } else if (s == "WIKI_LOCKED_ESSAYS_FROBBER") {
        return 19;
    } else if (s == "WIKI_LOG_FROBBER") {
        return 20;
    } else if (s == "LOC_CACHE_FROBBER") {
	return 21;
    }

    // add your frobber to the end of this list
    warn << "dsdc: #### INVALID FROBBER #### : " << s << "\n";
    return 666;
}

}

str dsdc_hostname;
static int dsdc_debug_level = 0;

bool show_debug (int lev) { return (lev <= dsdc_debug_level); }
void set_debug (int l) { dsdc_debug_level = l; }

void
set_hostname (const str &h)
{
  if (h)
    dsdc_hostname = h;
  else
    dsdc_hostname = myname ();
}

hash_t
hash_hash (const dsdc_key_t &h)
{
  u_int *p = (u_int *)h.base ();
  const char *end_c = h.base () + h.size ();
  u_int *end_i = (u_int *)end_c;
  u_int r = 0;
  while (p < end_i)
    r = r ^ *p++;
  return r;
}

str
key_to_str (const dsdc_key_t &k)
{
  str in (k.base (), k.size ());
  return armor64 (in);
}

bool
parse_hn (const str &in, str *host, int *port)
{
  static rxx host_port_rxx ("([.0-9A-Za-z_-]*)(:[0-9]+)?");
  if (!host_port_rxx.match (in))
    return false;
  str h = host_port_rxx[1];
  if (h && h.len () > 0 && h != "-")
    *host = h;
  str p = host_port_rxx[2];
  if (p && p.len () > 1) {
    const char *pc = p.cstr () + 1;
    p = pc;
    if (!convertint (p, port))
      return false;
  }
  return true;
}

str
dsdc_app_t::progname (const str &in, bool usepid) const
{
  strbuf b (in);
  if (progname_xtra () && ::progname == "dsdc")
    b << progname_xtra ();
  if (_daemonize && usepid) 
    b.fmt ("[%d]", getpid ());
  return b;
}

