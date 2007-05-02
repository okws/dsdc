
#include "dsdc_admin.h"
#include "aios.h"

#define __STDC_FORMAT_MACROS
#include <inttypes.h>

void 
tabbuf_t::indent ()
{
  u_int lim = _tabs * _tablen;
  for (u_int i = 0; i < lim; i++) {
    (*this) << " ";
  }
}

void 
tabbuf_t::open ()
{
  (*this) << " {\n";
  tab_in ();
}

void
tabbuf_t::close ()
{
  tab_out ();
  indent ();
  (*this) << "}\n";
}


void
tabbuf_t::outdiv (char c, int n, bool nl)
{
  n += _columns;
  for (int i = 0; i < n; i++) {
    fmt ("%c", c);
  }
  if (nl)
    (*this) << "\n";
}

static void
output_annotation (tabbuf_t &b, const dsdc_annotation_t &a)
{
  b.indent ();
  b << "Annotation: ";
  rpc_print (b, a, 0, NULL, NULL);
}

static void
output_hyper (tabbuf_t &b, const char *l, int64_t i)
{
  b.indent ();
  b << l << " = " << i << "\n";
}

static void
output_histogram (tabbuf_t &b, const char *l, const dsdc_histogram_t &h)
{
  if (h.samples == 0)
    return;

  b.indent ();
  b << l;
  b.open ();

  b.indent (); b.fmt ("avg   = %d\n", int (h.avg / h.scale_factor) );
  b.indent (); b.fmt ("min   = %d\n", int ( h.min / h.scale_factor) );
  b.indent (); b.fmt ("max   = %d\n", int ( h.max / h.scale_factor) );
  b.indent (); b.fmt ("total = %" PRId64 "\n", h.total / h.scale_factor );
  b.indent (); b.fmt ("nsamp = %d\n", int (h.samples));
  b.tab_in ();
  
  int64_t range = (h.max - h.min + 1);
  double sz =  (double)range/ (double)h.buckets.size () ;

  u_int mode_freq = 0;
  for (size_t i = 0; i < h.buckets.size (); i++) {
    if (h.buckets[i] > mode_freq)
      mode_freq = h.buckets[i];
  }
  int my_columns = b.columns () - 15;
  for (size_t i = 0; i < h.buckets.size (); i++) {
    b.indent ();
    b.fmt ("%6d: ", int ( (h.min + i*sz) / h.scale_factor ) );
    u_int n = (h.buckets[i] * my_columns)/mode_freq;
    b.outdiv ('*', n - b.columns (), false);
    b.fmt (" [%d]\n", h.buckets[i]);
  }
  b.tab_out ();
  b.close ();
}

static void
output_dataset (tabbuf_t &b, const char *l, const dsdc_dataset_t &d)
{
  b.indent ();
  b << l << " (duration=" << d.duration << "s)";
  b.open ();

  if (OUTPUT(N_ACTIVE) && d.n_active)
    output_hyper (b, "Num Active", *d.n_active);

  if (OUTPUT(CREATIONS)) 
    output_hyper (b, "Creations", d.creations);

  if (OUTPUT(PUTS)) 
    output_hyper (b, "Puts", d.puts);

  if (OUTPUT(MISSED_GETS))
    output_hyper (b, "Missed Gets", d.missed_gets);

  if (OUTPUT(MISSED_RMS))
    output_hyper (b, "Missed Removes", d.missed_removes);

  if (OUTPUT(RM_STATS)) {
    output_hyper (b, "Removals (explicit) ", d.rm_explicit);
    output_hyper (b, "Removals (make room)", d.rm_make_room);
    output_hyper (b, "Removals (clean)    ", d.rm_clean);
    output_hyper (b, "Removals (replace)  ", d.rm_replace);
    output_hyper (b, "Removals (total)    ",
		  d.rm_explicit + d.rm_make_room + d.rm_clean +
		  d.rm_replace);
  }

  if (OUTPUT(GETS))
    output_histogram (b, "Gets", d.gets);

  if (d.lifetime && OUTPUT(LIFETIME))
    output_histogram (b, "Lifetime", *d.lifetime);

  if (OUTPUT(OBJSZ))
    output_histogram (b, "Object Size", d.objsz);
  

  if (OUTPUT(DO_STATS)) {

    if (OUTPUT(GETS))
      output_histogram (b, "Gets (dead)", d.do_gets);

    if (OUTPUT(LIFETIME))
      output_histogram (b, "Lifetime (dead)", d.do_lifetime);

    if (OUTPUT(OBJSZ))
      output_histogram (b, "Object Size (dead)", d.do_objsz);
  }
  b.close ();
}

static void
output_stat (tabbuf_t &b, const dsdc_statistic_t &s)
{
  output_annotation (b, s.annotation);
  b.open ();
  if (OUTPUT(PER_EPOCH))
    output_dataset (b, "Per Epoch", s.epoch_data);
  if (OUTPUT(ALLTIME))
    output_dataset (b, "Alltime", s.alltime_data);
  b.close ();
}

static void
output_stats (tabbuf_t &b, const dsdc_statistics_t &s)
{
  for (size_t i = 0; i < s.size (); i++) {
    output_stat (b, s[i]);
  }
}

void
output_stats (tabbuf_t &b, const str &h, 
	      const dsdc_get_stats_single_res_t &res)
{
  b << "Slave: " << h ;
  b.open ();
  if (res.status == DSDC_OK) {
    output_stats (b, *res.stats);
  } else {
    b.indent ();
    b << "** Error result: ";
    rpc_print (b, res.status, 0, NULL, NULL);
    b << "\n";
  }
  b.close ();
}

void 
output_opts_t::parse_flags (const char *in)
{
  
#define C(l,u,F)                                   \
case l: _display_flags |=  (DISPLAY_##F); break;   \
case u: _display_flags &= ~(DISPLAY_##F); break

    for ( ; *in; in++) {
      switch (*in) {
	C ('r', 'R', RM_STATS);
	C ('p', 'P', PUTS);
	C ('m', 'M', MISSED_GETS);
	C ('d', 'D', DURATION);
	C ('g', 'G', GETS);
	C ('s', 'S', OBJSZ);
	C ('l', 'L', LIFETIME);
	C ('y', 'Y', DO_STATS);
	C ('e', 'E', PER_EPOCH);
	C ('a', 'A', ALLTIME);
	C ('c', 'C', CREATIONS);
	C ('n', 'N', N_ACTIVE);
	C ('z', 'Z', MISSED_RMS);
	  
      default: 
	warn ("Unrecognized format flag: '%c'\n", *in);
	break;
      }
    }
#undef C
}

output_opts_t output_opts;

