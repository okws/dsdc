
// -*-c++-*-
/* $Id$ */

#ifndef __DSDC_STATS_H__
#define __DSDC_STATS_H__

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

namespace dsdc {

    typedef enum { AC_NONE = 0,
                   AC_EXPLICIT = 1,
                   AC_MAKE_ROOM = 2,
                   AC_CLEAN = 3,
                   AC_REPLACE = 4,
                   AC_HIT = 5,
                   AC_EXPIRED = 6,
                   AC_NOT_FOUND = 7
                 } action_code_t ;

//-----------------------------------------------------------------------
//
// Two high level interface classes

    namespace annotation {
        class base_t {
        public:
            base_t () {}
            virtual ~base_t () {}
            virtual void mark_get_attempt (action_code_t t) = 0;
            virtual void collect (int g, int gie, int l, size_t os,
                                  bool del, action_code_t t) = 0;
            virtual void elem_create (size_t sz) = 0;
            virtual void missed_remove () = 0;
            virtual void missed_get () = 0;
            virtual dsdc_annotation_type_t get_type () const = 0;
            virtual bool to_xdr (dsdc_annotation_t *out) const = 0;

            static void to_xdr (const base_t *in, dsdc_annotation_t *out);

            bool same_type_as (const base_t &a2) const
            { return get_type () == a2.get_type (); }

            virtual void prepare_sweep () {}
            virtual void clear_stats2 () {}
            virtual void output_to_log (strbuf &b, time_t start, int len) {}

            virtual bool
            output (dsdc_statistic_t *out, const dsdc_dataset_params_t &p)
            { return false; }

            list_entry<base_t> _llnk;
        };
    };

    namespace stats {

        class collector_base_t {
        public:
            typedef annotation::base_t obj_t;

            collector_base_t () : _n_stats (0) {}
            virtual ~collector_base_t () {}

            virtual dsdc_res_t
            output (dsdc_statistics_t *sz,
                    const dsdc_dataset_params_t &p) = 0;

            virtual obj_t *
            alloc (const dsdc_annotation_t &a, bool newobj = true) = 0;

            virtual void prepare_sweep ();
            virtual void missed_remove (const dsdc_annotation_t &a);
            virtual void missed_get (const dsdc_annotation_t &a);
            virtual void output_to_log (strbuf &b) {}
            virtual bool is_collector2 () const { return false; }
            virtual void start_interval (void) {}

            void new_annotation (obj_t *b);
        protected:
            list<obj_t, &obj_t::_llnk> _lst;
            size_t _n_stats;
        };

        class collector_null_t : public collector_base_t {
        public:
            collector_null_t () : collector_base_t () {}

            dsdc::annotation::base_t *
            alloc (const dsdc_annotation_t &a, bool newobj = true)
            { return NULL; }

            virtual dsdc_res_t
            output (dsdc_statistics_t *sz,
                    const dsdc_dataset_params_t &p)
            { return DSDC_BAD_STATS; }



        };

        collector_base_t *collector ();
        void set_collector (collector_base_t *b);
    };

//
//-----------------------------------------------------------------------

};

#endif /* __DSDC_STATS_H__ */
