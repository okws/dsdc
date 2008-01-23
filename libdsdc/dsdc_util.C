
#include "dsdc_util.h"
#include "async.h"
#include "rxx.h"
#include "parseopt.h"

namespace dsdc {

  //-----------------------------------------------------------------------

  struct pair_t {
    const char *s;
    int i;
  };
  
  class tab_t {
  public:
    tab_t () {}
    const int *operator[] (const str &s) const { return _tab[s]; }
  protected:
    void init (const pair_t pairs[])
    {
      for (const pair_t *p = pairs; p->s; p++) {
	_tab.insert (p->s, p->i);
      }
      
      // Do a spot check!
      for (const pair_t *p = pairs; p->s; p++) {
	assert (*(*this)[p->s] == p->i);
      }
    } else if (s == "QUESTION_FROBBER") {
        return 27;
    }
  private:
    qhash<str, int> _tab;
  };
  
  class frobtab_t : public tab_t {
  public:
    frobtab_t () : tab_t () 
    {
      pair_t frobs[] = {
	{ "MATCHD_FRONTD_FROBBER", MATCHD_FRONTD_FROBBER },
	{ "MATCHD_FRONTD_USERCACHE_FROBBER", 
	  MATCHD_FRONTD_USERCACHE_FROBBER },
	{ "UBER_USER_FROBBER", UBER_USER_FROBBER },
	{ "PROFILE_STALKER_FROBBER", PROFILE_STALKER_FROBBER },
	{ "MATCHD_FRONTD_MATCHCACHE_FROBBER", 
	  MATCHD_FRONTD_MATCHCACHE_FROBBER },
	{ "GROUP_INFO_FROBBER", GROUP_INFO_FROBBER },
	{ "GTEST_SCORE_FROBBER", GTEST_SCORE_FROBBER },
	{ "PTEST_SCORE_FROBBER", PTEST_SCORE_FROBBER },
	{ "MTEST_SCORE_FROBBER", MTEST_SCORE_FROBBER },
	{ "CUPID_TEST_SCORE_FROBBER", CUPID_TEST_SCORE_FROBBER },
	{ "GTEST_SESSION_FROBBER", GTEST_SESSION_FROBBER },
	{ "PTEST_SESSION_FROBBER", PTEST_SESSION_FROBBER },
	{ "MTEST_SESSION_FROBBER", MTEST_SESSION_FROBBER },
	{ "MTEST_METADATA_FROBBER", MTEST_METADATA_FROBBER },
	{ "MTEST_STATS_FROBBER", MTEST_STATS_FROBBER },
	{ "SETTINGS_FROBBER", SETTINGS_FROBBER },
	{ "PROFILE_FUZZY_MATCHES_FROBBER", 
	  PROFILE_FUZZY_MATCHES_FROBBER },
	{ "AD_KEYWORD_FROBBER", AD_KEYWORD_FROBBER },
	{ "USER_LANG_FROBBER", 18 },
	{ "WIKI_LOCKED_ESSAYS_FROBBER", 19 },
	{ "WIKI_LOG_FROBBER", 20 },
	{ "LOC_CACHE_FROBBER", 21 },
	{ "STATS_LIST_FROBBER", 22 },
	{ "VOTE_SCORE_FROBBER", 23 } ,
	{ "VOTE_NOTE_FROBBER", 24 },
	{ "PROFILE_LANG_FROBBER", 25 },
	{ "VOTE_MATCH_FROBBER", 26 },
        { "QUESTION_FROBBER", 27 },
	{ NULL, 0 }
      };
      init (frobs);
    }
  };
  //-----------------------------------------------------------------------
  
  static frobtab_t g_frobtab;
  
  uint32_t frobber(str s) {
    const int *i = g_frobtab[s];
    if (i) { return *i; }
    warn << "dsdc: #### INVALID FROBBER #### : " << s << "\n";
    return 666;
  }
  //-----------------------------------------------------------------------
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

