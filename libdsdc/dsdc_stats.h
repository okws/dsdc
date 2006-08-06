
// -*-c++-*-
/* $Id$ */

#ifndef _DSDC_STATS_H
#define _DSDC_STATS_H

#include <limits.h>
#include "dsdc_prot.h"
#include "dsdc_ring.h"
#include "dsdc_state.h"
#include "dsdc_const.h"
#include "dsdc_util.h"
#include "dsdc_lock.h"
#include "ihash.h"
#include "list.h"
#include "async.h"
#include "arpc.h"
#include "qhash.h"
#include "ihash.h"

typedef enum { REMOVE_NONE = 0,
	       REMOVE_EXPLICIT = 1,
	       REMOVE_MAKE_ROOM = 2,
	       REMOVE_CLEAN = 3,
	       REMOVE_REPLACE = 4} remove_type_t;

namespace dsdc {

  namespace stats {

    struct histogram_t {

      histogram_t (int sf = 100) : 
	_scale_factor (sf), _min (INT_MAX), _max (INT_MIN) {}
      void add (int e);
      void reset ();
      void to_xdr (dsdc_histogram_t *out, size_t nbuc);
      int scale_factor () const { return _scale_factor; }
      int _scale_factor;
      vec<int> _data_points;
      int _min, _max;
    };

    struct dataset_t {
      dataset_t (bool per_epoch) : 
	_lifetime (per_epoch ? NULL : New histogram_t ()),
	_n_active (per_epoch ? NULL : New int ()),
	_per_epoch (per_epoch) { clear (); }
      void clear ();
      ~dataset_t () { if (_lifetime) delete _lifetime; }

      histogram_t _gets, *_lifetime, _objsz;

      void prepare_sweep () { if (_n_active) *_n_active = 0; }
      void inc_n_active () { if (_n_active) (*_n_active) ++; }
      void n_gets (int g);

      // do = "deleted object"
      histogram_t _do_gets, _do_lifetime, _do_objsz;  

      int _creations;
      int _puts;
      int _missed_gets, _missed_removes;
      int _rm_explicit, _rm_make_room, _rm_clean, _rm_replace;
      int *_n_active;

      bool output (dsdc_dataset_t *out, const dsdc_dataset_params_t &p);

      time_t _start_time;

      const bool _per_epoch;
    };
  };

  namespace annotation {

    class int_t;
    class base_t {
    public:
      base_t () : _alltime (false), _per_epoch (true) {}

      virtual ~base_t () {}
      virtual dsdc_annotation_type_t get_type () const = 0;
      
      bool same_type_as (const base_t &a2) const
      { return get_type () == a2.get_type (); }
    
      static void to_xdr (const base_t *in, dsdc_annotation_t *out);

      virtual bool to_xdr (dsdc_annotation_t *a) const = 0;

      bool output (dsdc_statistic_t *out, const dsdc_dataset_params_t &p);

      void elem_create (int n) 
      { 
	_alltime._creations ++ ; 
	_per_epoch._creations ++; 
	objsz (n);
      }

      void prepare_sweep () 
      {
	_alltime.prepare_sweep ();
	_per_epoch.prepare_sweep ();
      }

      void n_gets (int g, int gie);
      void missed_get ()
      { _alltime._missed_gets ++; _per_epoch._missed_gets ++; }
      void missed_remove ()
      { _alltime._missed_removes ++; _per_epoch._missed_removes ++; }
      void put ()
      { _alltime._puts ++ ; _per_epoch._puts ++; }

      void inc_n_active ()
      { _alltime.inc_n_active (); _per_epoch.inc_n_active (); }

      void dead_object_n_gets (int n) 
      { _alltime._do_gets.add (n); _per_epoch._do_gets.add (n); }
      void time_alive (int n) { _alltime._lifetime->add (n); }
      void dead_object_time_alive (int n)
      { _alltime._do_lifetime.add (n); _per_epoch._do_lifetime.add (n); }
      void objsz (int n)
      { _alltime._objsz.add (n); _per_epoch._objsz.add (n); }
      void dead_object_objsz (int n)
      { _alltime._do_objsz.add (n); _per_epoch._do_objsz.add (n); }

      void collect (int g, int gie, int l, int os, bool del, remove_type_t t);
      void dead_object (remove_type_t t);


      list_entry<base_t> _llnk;
    private:
      stats::dataset_t _alltime, _per_epoch;
    };


    class int_t : public base_t {
    public:
      int_t (int i) : base_t (), _val (i) {}

      bool to_xdr (dsdc_annotation_t *a) const
      {
	a->set_typ (DSDC_INT_ANNOTATION);
	*(a->i) = _val;
	return true;
      }

      dsdc_annotation_type_t get_type () const { return DSDC_INT_ANNOTATION; }

      int _val;
      ihash_entry<int_t> _hlnk;
    };

    class collector_t;
    class int_factory_t {
    public:
      int_t *alloc (int i, collector_t *c, bool newobj = true);
      ihash<int, int_t, &int_t::_val, &int_t::_hlnk> _tab;
    };

#ifndef DSDC_NO_CUPID
    class frobber_t : public base_t {
    public:
      frobber_t (ok_frobber_t f) : base_t (), _val (int (f)) {}
      bool to_xdr (dsdc_annotation_t *a) const
      {
	a->set_typ (DSDC_CUPID_ANNOTATION);
	*(a->frobber) = ok_frobber_t (_val);
	return true;
      }
      
      dsdc_annotation_type_t get_type () const {return DSDC_CUPID_ANNOTATION;}
      
      int _val;
      ihash_entry<frobber_t> _hlnk;
    };

    class frobber_factory_t {
    public:
      frobber_t *alloc (ok_frobber_t i, collector_t *c, bool newobj = true);
      ihash<int, frobber_t, &frobber_t::_val, &frobber_t::_hlnk> _tab;
    };
#endif /* DSDC_NO_CUPID */

    class collector_t {
    public:
      collector_t () : _n_stats (0) {}
      int_t *int_alloc (int i);
      
      void new_annotation (base_t *b);
      base_t *alloc (const dsdc_annotation_t &a, bool newobj = true);
      void missed_get (const dsdc_annotation_t &a);
      void missed_remove (const dsdc_annotation_t &a);
      list<base_t, &base_t::_llnk> _lst;
      int_factory_t _int_factory;
      dsdc_res_t output (dsdc_statistics_t *sz, 
			 const dsdc_dataset_params_t &p);
      void prepare_sweep ();
      u_int _n_stats;
#ifndef DSDC_NO_CUPID
      frobber_t *frobber_alloc (ok_frobber_t f);
      frobber_factory_t _frobber_factory;
#endif /* DSDC_NO_CUPID */
    };
    extern collector_t collector;

  };
};


#endif /* _DSDC_STATS_H_ */
