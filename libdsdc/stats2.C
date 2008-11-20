
#include "dsdc_stats2.h"

static int
millisec_diff (const struct timespec &ts1, const struct timespec &ts2)
{
    int ret = 0;
    ret += (ts1.tv_sec - ts2.tv_sec) * 1000 +
           (ts1.tv_nsec - ts2.tv_nsec) / 1000000;
    return ret;
}

#define SEP ", "
#define DSDC_STAT_TOK "DSDC-STAT"

namespace dsdc {

    namespace stats {

        //--------------------------------------------------

        void
        dist_v2_t::insert (u_int32_t v)
        {
            if (v < _min)  _min = v;
            if (v > _max)  _max = v;

            _sum += v;
            _sum2 += v*v;
            _n ++;

            _hit = true;
        }

        //--------------------------------------------------

        void
        dist_v2_t::clear ()
        {
            _min = UINT_MAX;
            _max = 0;
            _sum = 0;
            _sum2 = 0;
            _n = 0;
            _hit = false;
        }

        //--------------------------------------------------

        void
        dist_v2_t::output_to_log (strbuf &b)
        {
            b << SEP << (_hit ? _min : 0UL)  << " " << _max << " " << _n
            << " " << _sum << " " << _sum2;
        }

        //--------------------------------------------------

        dist_v2_t::dist_v2_t () { clear (); }

        //--------------------------------------------------

        stats_v2_t::stats_v2_t () { clear (); }

        //--------------------------------------------------

        void
        stats_v2_t::clear ()
        {
            _dist_insert_sz.clear ();
            _dist_obj_sz.clear ();

            _n_get_hit = _n_get_notfound = _n_get_timeout = 0;

            _n_rm_explicit = _n_rm_replace = _n_rm_pushout = 0;
            _n_rm_timeout = _n_rm_clean = _n_rm_miss = 0;
        }

        //--------------------------------------------------

        void
        stats_v2_t::output_to_log (strbuf &b)
        {
            _dist_insert_sz.output_to_log (b);
            _dist_obj_sz.output_to_log (b);
            b << SEP << _n_get_hit
            << SEP << _n_get_notfound
            << SEP << _n_get_timeout
            << SEP << _n_rm_explicit
            << SEP << _n_rm_replace
            << SEP << _n_rm_pushout
            << SEP << _n_rm_timeout
            << SEP << _n_rm_clean
            << SEP << _n_rm_miss;
        }

        //--------------------------------------------------

    };

    namespace annotation {

        //--------------------------------------------------

        void
        v2_t::mark_get_attempt (action_code_t ac)
        {
            switch (ac) {
            case AC_HIT:
                _stats._n_get_hit++;
                break;
            case AC_NOT_FOUND:
                _stats._n_get_notfound++;
                break;
            case AC_EXPIRED:
                _stats._n_get_timeout++;
                break;
            default:
                warn << "invalid mark_get_attempt call: " << int (ac) << "\n";
                break;
            }
        }

        //--------------------------------------------------

        void v2_t::missed_get () {}

        //--------------------------------------------------

        void
        v2_t::collect (int dummy1, int dummy2, int lifetime,
                       size_t objsz, bool del, action_code_t ac)
        {
            if (del) {
                switch (ac) {
                case AC_CLEAN:
                    _stats._n_rm_clean ++;
                    break;
                case AC_EXPLICIT:
                    _stats._n_rm_explicit ++;
                    break;
                case AC_REPLACE:
                    _stats._n_rm_replace ++;
                    break;
                case AC_MAKE_ROOM:
                    _stats._n_rm_pushout ++;
                    break;
                case AC_EXPIRED:
                    _stats._n_rm_timeout ++;
                    break;
                default:
                    warn << "invalid collect/delete call: "
                    << int (ac) << "\n";
                    break;
                }
            } else {
                _stats._dist_obj_sz.insert (objsz);
            }
        }

        //--------------------------------------------------

        void
        v2_t::elem_create (size_t sz)
        {
            _stats._dist_insert_sz.insert (sz);
        }

        //--------------------------------------------------

        void
        v2_t::missed_remove ()
        {
            _stats._n_rm_miss++;
        }

        //--------------------------------------------------

        dsdc_annotation_type_t
        int2_t::get_type () const
        {
            return DSDC_INT_ANNOTATION;
        }

        //--------------------------------------------------

        dsdc_annotation_type_t
        str2_t::get_type () const
        {
            return DSDC_STR_ANNOTATION;
        }

        //--------------------------------------------------

        bool
        int2_t::to_xdr (dsdc_annotation_t *out) const
        {
            out->set_typ (DSDC_INT_ANNOTATION);
            *out->i = _val;
            return true;
        }

        //--------------------------------------------------

        bool
        str2_t::to_xdr (dsdc_annotation_t *out) const
        {
            out->set_typ (DSDC_STR_ANNOTATION);
            *out->s = _val;
            return true;
        }

        //--------------------------------------------------

        void v2_t::prepare_sweep () {}

        //--------------------------------------------------

        bool
        v2_t::output (dsdc_statistics_t *out, const dsdc_dataset_params_t &p)
        { return false; }

        //--------------------------------------------------

        void v2_t::clear_stats2 () { _stats.clear (); }

        //--------------------------------------------------

        void
        int2_t::output_type_to_log (strbuf &b)
        {
            b << "ID" << _val;
        }

        //--------------------------------------------------

        void
        str2_t::output_type_to_log (strbuf &b)
        {
            b << _val;
        }

        //--------------------------------------------------

        void
        v2_t::output_to_log (strbuf &b, time_t start, int len)
        {
            b << DSDC_STAT_TOK << " " << start << " " << len << " | ";
            output_type_to_log (b);
            _stats.output_to_log (b);
            b << "\n";
        }

        //--------------------------------------------------

    };

    namespace stats {

        //--------------------------------------------------

        dsdc_res_t
        collector2_t::output (dsdc_statistics_t *sz,
                              const dsdc_dataset_params_t &p)
        {
            return DSDC_BAD_STATS;
        }

        //--------------------------------------------------

        annotation::str2_t *
        collector2_t::str_alloc (const str &s)
        {
            return _str_factory.alloc (s, this, true);
        }

        //--------------------------------------------------

        annotation::int2_t *
        collector2_t::int_alloc (u_int32_t i)
        {
            return _int_factory.alloc (i, this, true);
        }

        //--------------------------------------------------

        annotation::str2_t *
        str2_factory_t::alloc (const str &s, collector_base_t *c, bool newobj)
        {
            annotation::str2_t *ret;
            if (!(ret = _tab[s]) && newobj) {
                ret = New annotation::str2_t (s);
                _tab.insert (ret);
                c->new_annotation (ret);
            }
            return ret;
        }

        //--------------------------------------------------

        annotation::int2_t *
        int2_factory_t::alloc (u_int32_t i, collector_base_t *c, bool newobj)
        {
            annotation::int2_t *ret;
            if (!(ret = _tab[i]) && newobj) {
                ret = New annotation::int2_t (i);
                _tab.insert (ret);
                c->new_annotation (ret);
            }
            return ret;
        }

        //--------------------------------------------------

        annotation::base_t *
        collector2_t::alloc (const dsdc_annotation_t &a, bool newobj)
        {
            annotation::base_t *ret = NULL;
            switch (a.typ) {
            case DSDC_STR_ANNOTATION:
                ret = _str_factory.alloc (*a.s, this, newobj);
                break;
            case DSDC_INT_ANNOTATION:
                ret = _int_factory.alloc (*a.i, this, newobj);
                break;
            case DSDC_CUPID_ANNOTATION:
                ret = _int_factory.alloc (u_int32_t (*a.frobber),
                                          this, newobj);
                break;
            default:
                break;
            }
            return ret;
        }

        //--------------------------------------------------

        void
        collector2_t::output_to_log (strbuf &b)
        {
            prepare_sweep ();

            // First mark down the size of objects alive in the cache
            // at the time of the collection.

            int len = millisec_diff (sfs_get_tsnow (), _start);

            for (obj_t *a = _lst.first; a; a = _lst.next (a)) {
                a->output_to_log (b, _start.tv_sec, len);
                a->clear_stats2 ();
            }
        }

        //--------------------------------------------------

    };


};
