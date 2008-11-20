
#include "dsdc_stats.h"

namespace dsdc {
    namespace annotation {

        //--------------------------------------------------------

        void
        base_t::to_xdr (const base_t *in, dsdc_annotation_t *out)
        {
            if (in) {
                in->to_xdr (out);
            } else {
                out->set_typ (DSDC_NO_ANNOTATION);
            }
        }

        //--------------------------------------------------------

    }

    namespace stats {

        void
        collector_base_t::prepare_sweep ()
        {
            obj_t *b;
            for (b = _lst.first; b ; b = _lst.next (b)) {
                b->prepare_sweep ();
            }
        }

        //--------------------------------------------------------


        void
        collector_base_t::new_annotation (obj_t *ret)
        {
            _lst.insert_head (ret);
            _n_stats ++;
        }

        //--------------------------------------------------------

        void
        collector_base_t::missed_get (const dsdc_annotation_t &a)
        {
            obj_t *b = alloc (a, true);
            if (b) b->missed_get ();
        }

        //--------------------------------------------------------

        void
        collector_base_t::missed_remove (const dsdc_annotation_t &a)
        {
            obj_t *b = alloc (a, true);
            if (b) b->missed_remove ();
        }

        //--------------------------------------------------------

        static collector_base_t *g_collector;

        //--------------------------------------------------------

        collector_base_t *
        collector ()
        {
            if (!g_collector) {
                g_collector = New collector_null_t ();
            }
            return g_collector;
        }

        //--------------------------------------------------------

        void
        set_collector (collector_base_t *b)
        {
            if (g_collector)
                delete g_collector;
            g_collector = b;
        }

        //--------------------------------------------------------

    };
};
