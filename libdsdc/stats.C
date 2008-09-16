
#include "dsdc_stats.h"
#include "dsdc_prot.h"

namespace dsdc {

    namespace annotation {

        collector_t collector;

        int_t *
        collector_t::int_alloc (int i)
        {
            return _int_factory.alloc (i, this, true);
        }

        void
        collector_t::new_annotation (base_t *ret)
        {
            _lst.insert_head (ret);
            _n_stats ++;
        }

        base_t *
        collector_t::alloc (const dsdc_annotation_t &a, bool newobj)
        {
            base_t *ret = NULL;
            switch (a.typ) {
            case DSDC_INT_ANNOTATION:
                ret = _int_factory.alloc (*a.i, this, newobj);
                break;

#ifndef DSDC_NOCUPID
            case DSDC_CUPID_ANNOTATION:
                ret = _frobber_factory.alloc (*a.frobber, this, newobj);
                break;
#endif /* DSDC_NO_CUPID */

            default:
                break;
            }
            return ret;
        }

        int_t *
        int_factory_t::alloc (int i, collector_t *c, bool newobj)
        {
            int_t *ret;
            if (!(ret = _tab[i]) && newobj) {
                ret = New int_t (i);
                _tab.insert (ret);
                c->new_annotation (ret);
            }
            return ret;
        }

#ifndef DSDC_NO_CUPID

        frobber_t *
        collector_t::frobber_alloc (ok_frobber_t f)
        {
            return _frobber_factory.alloc (f, this, true);
        }

        frobber_t *
        frobber_factory_t::alloc (ok_frobber_t f, collector_t *c, bool newobj)
        {
            frobber_t *ret;
            if (!(ret = _tab[int(f)]) && newobj) {
                ret = New frobber_t (f);
                _tab.insert (ret);
                c->new_annotation (ret);
            }
            return ret;
        }
#endif /* DSDC_NO_CUPID */

        bool
        base_t::output (dsdc_statistic_t *out, const dsdc_dataset_params_t &p)
        {
            bool ok = true;
            if (!to_xdr (&out->annotation) ||
                !_per_epoch.output (&out->epoch_data, p) ||
                !_alltime.output (&out->alltime_data, p))
                ok = false;

            _per_epoch.clear ();
            _alltime._gets.reset ();
            _alltime._lifetime->reset ();
            return ok;
        }

        dsdc_res_t
        collector_t::output (dsdc_statistics_t *out,
                             const dsdc_dataset_params_t &p)
        {
            out->setsize (_n_stats);
            size_t i;
            base_t *b;
            bool ok = true;
            for (b = _lst.first, i = 0; b && ok; b = _lst.next (b), i++) {
                ok = b->output (&((*out)[i]), p);
            }
            return (ok ? DSDC_OK : DSDC_BAD_STATS);
        }

        void
        collector_t::prepare_sweep ()
        {
            base_t *b;
            for (b = _lst.first; b ; b = _lst.next (b)) {
                b->prepare_sweep ();
            }
        }

        void
        collector_t::missed_get (const dsdc_annotation_t &a)
        {
            base_t *b = alloc (a, true);
            if (b) b->missed_get ();
        }

        void
        collector_t::missed_remove (const dsdc_annotation_t &a)
        {
            base_t *b = alloc (a, true);
            if (b) b->missed_remove ();
        }

        void
        base_t::to_xdr (const base_t *in, dsdc_annotation_t *out)
        {
            if (in) {
                in->to_xdr (out);
            } else {
                out->set_typ (DSDC_NO_ANNOTATION);
            }
        }
    }

    namespace stats {

        void histogram_t::add (int e)
        {
            int d = e * _scale_factor;
            _data_points.push_back (d);
            if (d > _max) _max = d;
            if (d < _min) _min = d;
        }

        void
        histogram_t::reset ()
        {
            _data_points.clear ();
            _min = INT_MAX;
            _max = INT_MIN;
        }

        void
        histogram_t::to_xdr (dsdc_histogram_t *h, size_t nbuck)
        {
            h->scale_factor = _scale_factor;
            h->samples = _data_points.size ();
            if (_data_points.size () == 0) {
                h->min = h->max = h->avg = h->total = 0;
                h->samples = 0;
                return;
            }

            assert (_max >= _min);
            assert (nbuck > 0);

            h->min = _min;
            h->max = _max;

            int range = _max - _min + 1;
            int bsz = range / nbuck;
            if (bsz == 0) bsz = 1;

            int64_t tot = 0;

            h->buckets.setsize (nbuck);
            memset (h->buckets.base (), 0, sizeof (unsigned) * nbuck);

            for (size_t i = 0; i < _data_points.size (); i++) {
                const int &d = _data_points[i];
                assert (d >= _min && d <= _max);

                // If d == _max, then it's technically one bucket over, but
                // push d in the last bucket.
                size_t i = (d < _max) ? ((d - _min) / bsz) : (nbuck - 1);

                // there seem to be other rounding problems that i can't figure
                // out exactly, but just play it safe....
                if (i >= nbuck) { i = nbuck - 1; }

                h->buckets[i] ++;
                tot += d;
            }
            h->avg = (tot / _data_points.size ());
            h->total = tot;
        }

        void
        dataset_t::clear ()
        {
            _gets.reset ();
            if (_lifetime) _lifetime->reset ();
            _do_gets.reset ();
            _do_lifetime.reset ();

            _objsz.reset ();
            _do_objsz.reset ();

            _creations = 0;
            _puts = 0;
            _missed_gets = 0;
            _missed_removes = 0;

            _rm_explicit = _rm_make_room = _rm_clean = _rm_replace = 0;

            _start_time = sfs_get_timenow ();
        }

        bool
        dataset_t::output (dsdc_dataset_t *out, const dsdc_dataset_params_t &p)
        {
            out->creations = _creations;
            out->puts = _puts;
            out->missed_gets = _missed_gets;
            out->missed_removes = _missed_removes;
            out->rm_explicit = _rm_explicit;
            out->rm_make_room  = _rm_make_room;
            out->rm_clean = _rm_clean;
            out->rm_replace = _rm_replace;
            out->duration = sfs_get_timenow () - _start_time;

            _gets.to_xdr (&out->gets, p.gets_n_buckets);
            _do_gets.to_xdr (&out->do_gets, p.gets_n_buckets);
            _objsz.to_xdr (&out->objsz, p.objsz_n_buckets);

            if (_lifetime) {
                out->lifetime.alloc ();
                _lifetime->to_xdr (out->lifetime, p.lifetime_n_buckets);
            }

            if (_n_active) {
                out->n_active.alloc ();
                *out->n_active = *_n_active;
            }

            _do_lifetime.to_xdr (&out->do_lifetime, p.lifetime_n_buckets);
            _do_objsz.to_xdr (&out->do_objsz, p.objsz_n_buckets);
            return true;
        }

        void
        dataset_t::n_gets (int g)
        {
            _gets.add (g);
        }
    }

    namespace annotation {

        void
        base_t::n_gets (int g, int gie)
        { _alltime.n_gets (g); _per_epoch.n_gets (gie); }

        void
        base_t::collect (int g, int gie, int l, int os, bool del, remove_type_t t)
        {
            inc_n_active ();
            if (del) {
                dead_object_n_gets (g);
                dead_object_time_alive (l);
                dead_object_objsz (os);
                dead_object (t);
            } else {
                /* objsz filled in when objects are created */
                n_gets (g, gie); // gie = 'Gets in Epoch'
                time_alive (l);
            }
        }


        void
        base_t::dead_object (remove_type_t t)
        {
            switch (t) {
            case REMOVE_EXPLICIT:
                _alltime._rm_explicit ++;
                _per_epoch._rm_explicit ++;
                break;
            case REMOVE_MAKE_ROOM:
                _alltime._rm_make_room ++;
                _per_epoch._rm_make_room ++;
                break;
            case REMOVE_CLEAN:
                _alltime._rm_clean++;
                _per_epoch._rm_clean++;
                break;
            case REMOVE_REPLACE:
                _alltime._rm_replace ++;
                _per_epoch._rm_replace ++;
                break;
            default:
                break;
            }
        }

    }
}



