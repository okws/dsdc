
// -*-c++-*-
/* $Id$ */

#ifndef _DSDC_ADMIN_H_
#define _DSDC_ADMIN_H_

#include "async.h"
#include "dsdc_prot.h"
#include "arpc.h"
#include "tame.h"

#define DISPLAY_CREATIONS   (1 << 0)
#define DISPLAY_RM_STATS    (1 << 1)
#define DISPLAY_PUTS        (1 << 2)
#define DISPLAY_MISSED_GETS (1 << 3)
#define DISPLAY_DURATION    (1 << 4)
#define DISPLAY_GETS        (1 << 5)
#define DISPLAY_OBJSZ       (1 << 6)
#define DISPLAY_LIFETIME    (1 << 7)
#define DISPLAY_DO_STATS    (1 << 8)
#define DISPLAY_PER_EPOCH   (1 << 9)
#define DISPLAY_ALLTIME     (1 << 10)
#define DISPLAY_N_ACTIVE    (1 << 11)

struct output_opts_t {
  output_opts_t () : _display_flags (0) {}
  u_int _display_flags;
  void set_all_flags () { _display_flags = 0xffffffff; }
  void parse_flags (const char *in);
};

struct tabbuf_t : public strbuf {
  tabbuf_t (int c) : strbuf (), _tabs (0), _tablen (2), _columns (c) {}
  void tab_in () { _tabs ++; }
  void tab_out () { assert (--_tabs >= 0); }
  void indent ();
  void open ();
  void close ();
  void outdiv (char c, int n = 0, bool nl = true);

  void set_columns (int i) { _columns = i; }
  int columns () const { return _columns; }

  int _tabs;
  int _tablen;
  int _columns;
};

extern output_opts_t output_opts;

#define OUTPUT(x) (output_opts._display_flags & DISPLAY_##x)


void output_stats (tabbuf_t &b, const str &h, 
		   const dsdc_get_stats_single_res_t &res);

#endif /* _DSDC_ADMIN_H_ */
