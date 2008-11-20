
// -*-c++-*-
/* $Id: dsdc_stats.h 95842 2008-09-16 00:23:16Z max@OKCUPID.COM $ */

#ifndef __DSDC_STATS1_H__
#define __DSDC_STATS1_H__

#include "async.h"
#include "dsdc_prot.h"
#include "dsdc_stats.h"
#include "dsdc_stats1.h"

//
// Version 1 stats objects, etc.
//

namespace dsdc {

    namespace stats {

        //-----------------------------------------------------------------------

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

        //-----------------------------------------------------------------------

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

        //-----------------------------------------------------------------------

        class int_t;

        //-----------------------------------------------------------------------

        class base1_t : public base_t {
        public:
            base1_t () : base_t (), _alltime (false), _per_epoch (true) {}

            virtual ~base1_t () {}

            void mark_get_attempt (action_code_t t) {}

            bool output (dsdc_statistic_t *out, const dsdc_dataset_params_t &p);

            void elem_create (size_t n)
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

            void collect (int g, int gie, int l, size_t os, bool del,
                          action_code_t t);
            void dead_object (action_code_t t);


        private:
            stats::dataset_t _alltime, _per_epoch;
        };

        //-----------------------------------------------------------------------

        class int_t : public base1_t {
        public:
            int_t (dsdc_id_t i) : base1_t (), _val (i) {}

            bool to_xdr (dsdc_annotation_t *a) const
            {
                a->set_typ (DSDC_INT_ANNOTATION);
                *(a->i) = _val;
                return true;
            }

            dsdc_annotation_type_t get_type () const
            { return DSDC_INT_ANNOTATION; }

            dsdc_id_t _val;
            ihash_entry<int_t> _hlnk;
        };

#ifndef DSDC_NO_CUPID

        //-----------------------------------------------------------------------

        class frobber_t : public base1_t {
        public:
            frobber_t (ok_frobber_t f) : base1_t (), _val (int (f)) {}
            bool to_xdr (dsdc_annotation_t *a) const
            {
                a->set_typ (DSDC_CUPID_ANNOTATION);
                *(a->frobber) = ok_frobber_t (_val);
                return true;
            }

            dsdc_annotation_type_t get_type () const
            { return DSDC_CUPID_ANNOTATION;}

            int _val;
            ihash_entry<frobber_t> _hlnk;
        };
#endif /* DSDC_NO_CUPID */

        //-----------------------------------------------------------------------

    }

    namespace stats {

        class int_factory_t {
        public:
            typedef annotation::int_t typ;

            typ *alloc (dsdc_id_t i, collector_base_t *c, bool newobj = true);
            ihash<dsdc_id_t, typ, &typ::_val, &typ::_hlnk> _tab;
        };

#ifndef DSDC_NO_CUPID
        class frobber_factory_t {
        public:
            typedef annotation::frobber_t typ;

            typ *alloc (ok_frobber_t i, collector_base_t *c, bool newobj = true);

            ihash<int, typ, &typ::_val, &typ::_hlnk> _tab;
        };
#endif /* DSDC_NO_CUPID */

        class collector1_t : public collector_base_t {
        public:
            collector1_t () : collector_base_t (), _n_stats (0) {}

            obj_t *int_alloc (dsdc_id_t i);

            obj_t *str_alloc (const str &s) { return NULL; }


            annotation::base_t *
            alloc (const dsdc_annotation_t &a, bool newobj = true);

            int_factory_t _int_factory;

            dsdc_res_t output (dsdc_statistics_t *sz,
                               const dsdc_dataset_params_t &p);
            u_int _n_stats;
#ifndef DSDC_NO_CUPID
            annotation::frobber_t *frobber_alloc (ok_frobber_t f);
            frobber_factory_t _frobber_factory;
#endif /* DSDC_NO_CUPID */
        };

        //-----------------------------------------------------------------------
    };
};


#endif /* _DSDC_STATS1_H_ */
