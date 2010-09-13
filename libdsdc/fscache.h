// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#ifndef _DSDC_FSCACHE_H_
#define _DSDC_FSCACHE_H_

#include "async.h"
#include "tame.h"
#include "aiod.h"
#include "crypt.h"
#include "tame_lock.h"
#include "tame_nlock.h"
#include "dsdc_const.h"
#include "aiod2_client.h"

namespace fscache {

    //-----------------------------------------------------------------------

    typedef enum {
        BACKEND_SIMPLE = 0,
        BACKEND_AIOD = 1,
        BACKEND_SIMPLE_FAST = 2,
        BACKEND_THREADS = 3,
        BACKEND_HYBRID = 4,
        BACKEND_AIOD2 = 5,
        BACKEND_ERROR = 6
    } backend_typ_t;

    //-----------------------------------------------------------------------

    backend_typ_t str2backend (const str &s);
    str backend2str (backend_typ_t typ);

    //-----------------------------------------------------------------------

    enum {
        DEBUG_OP_TRACE = 1 << 0
    };

    class cfg_t {
    public:
        cfg_t (bool fake_jail = false);

        backend_typ_t backend () const { return _backend; }
        int n_levels () const { return _n_levels; }
        int n_dig () const { return _n_dig; }
        str root () const;
        int n_aiods () const { return _n_aiods; }
        size_t shmsize () const { return _shmsize; }
        size_t maxbuf () const { return _maxbuf; }
        int file_mode () const { return _file_mode; }
        size_t blocksz () const { return _blocksz; }
        void set_fake_jail (bool b) { _fake_jail = b; }
        void set_skip_sha (bool b) { _skip_sha = b; }
        bool skip_sha () const { return _skip_sha; }
        size_t max_packet_size () const { return _max_packet_size; }

        u_int64_t debug_level () const { return _debug; }
        void set_debug_options (const char *in);
        static str get_debug_docs ();
        static str get_debug_optstr ();
        bool debug (u_int64_t u) const { return (u & _debug) == u; }
        void set_debug_flag (u_int64_t f) { _debug |= f; }
        time_t rollover_time () const { return _rollover_time; }
        time_t write_delay () const { return _write_delay; }
        size_t write_delay_parallelism () const { return _wdp; }
        bool write_atomic () const { return _write_atomic; }

        backend_typ_t _backend;
        int _n_levels, _n_dig;
        str _root;
        int _n_aiods;
        size_t _shmsize, _maxbuf, _blocksz;
        int _file_mode;
        str _jaildir;
        bool _fake_jail;
        bool _skip_sha;
        u_int64_t _debug;
        time_t _rollover_time;
        time_t _write_delay;
        size_t _wdp; // write delay parallelism
        size_t _max_packet_size;
        bool _write_atomic;
    };

    //-----------------------------------------------------------------------

    typedef callback<void, int,time_t,str>::ref cbits_t;
    typedef event<size_t>::ref ev_sz_t;

    //-----------------------------------------------------------------------

    class file_id_t {
    public:
        file_id_t (const str &name, u_int32_t index)
                : _name (name), _index (index) {}
        file_id_t () {}
        str name () const { return _name; }
        str fullpath (int lev, int ndig = 0) const;
        u_int32_t get_index () const { return _index; }
        str to_str () const;
    private:
        str _name;
        u_int32_t _index;
    };

    //-----------------------------------------------------------------------

    class backend_t {
    public:
        backend_t () {}
        virtual ~backend_t () {}
        virtual void file2str (str fn, evis_t cb) = 0;

        // str2file_inner is in the case of simple, fast and threaded
        // called up to twice per str2file. The first call tries and maybe
        // fails to make a parent dir.  Then the parent dirs are created
        // and the second call is made.
        virtual void str2file (str f, str s, int mode, evi_t cb)
        { str2file_T (f, s, mode, cb); }
        virtual void str2file_inner (str f, str s, int md, bool cf, evi_t cb)
        { assert (false); }


        virtual void remove (str f, evi_t ev) = 0;
        virtual void mkdir (str s, int mode, evi_t cb) = 0;
        virtual void statvfs (str d, struct statvfs *buf, evi_t ev) = 0;
        virtual bool init () { return true; }
        virtual void stat (str f, struct stat *sb, evi_t ev) {}
    protected:
        void mk_parent_dirs (str s, int mode, evi_t ev, CLOSURE);
    private:
        void str2file_T (str f, str s, int mode, evi_t ev, CLOSURE);
    };

    //-----------------------------------------------------------------------

    class engine_t {
    public:
        engine_t (const cfg_t *c);
        virtual ~engine_t ();

        virtual bool init ();
        virtual void shutdown (evv_t ev) { ev->trigger (); }

        virtual void load (file_id_t id, cbits_t cb) { load_T (id, cb); }
        virtual void store (file_id_t id, time_t tm, str data, evi_t ev)
        { store_T (id, tm, data, ev); }
        virtual void remove (file_id_t id, evi_t ev)
        { remove_T (id, ev); }

        str filename (file_id_t id) const;
        void statvfs (struct statvfs *buf, evi_t ev, CLOSURE);

        bool skip_sha () const { return _cfg->skip_sha (); }

        void rotate (CLOSURE);

    private:
        void load_T (file_id_t id, cbits_t cb, CLOSURE);
        void store_T (file_id_t id, time_t tm, str data, evi_t ev, CLOSURE);
        void remove_T (file_id_t id, evi_t ev, CLOSURE);

    protected:
        const cfg_t *_cfg;
        ptr<backend_t> _backend;         // the current backend
        vec<ptr<backend_t> > _backend_v; // all backends, including alternates
        ptr<bool> _alive;
    };

    //-----------------------------------------------------------------------

    class write_delay_engine_t : public engine_t {
    public:
        write_delay_engine_t (const cfg_t *c);
        ~write_delay_engine_t ();

        typedef tame::lock_handle_t<str> lock_handle_t;
        typedef event<ptr<lock_handle_t> >::ref lock_ev_t;
        
        virtual void load (file_id_t id, cbits_t cb) 
        { write_delay_engine_t::load_T (id, cb); }
        virtual void store (file_id_t id, time_t tm, str data, evi_t ev)
        { write_delay_engine_t::store_T (id, tm, data, ev); }
        virtual void remove (file_id_t id, evi_t ev) 
        { write_delay_engine_t::remove_T (id, ev); }

        virtual bool init ();
        virtual void shutdown (evv_t ev) { shutdown_T (ev); }
        bool use_cache () const { return _cfg->write_delay () && m_enabled; }
        void lock (file_id_t fid, lock_ev_t ev, CLOSURE);
        bool set_write_delay (bool s);

        struct node_t {
            node_t (file_id_t fid, time_t t, str d, bool dirty);
            void store (engine_t *e, evv_t ev, CLOSURE);
            void mark_dirty () { m_dirty = true; }
            bool is_dirty () const { return m_dirty; }
            file_id_t m_fid;
            str m_filename;
            time_t m_file_time;
            str m_data;
            time_t m_store_time;
            tailq_entry<node_t> m_qlink;
            ihash_entry<node_t> m_hlink;
            bool m_dirty;
        };

    private:
        void insert (file_id_t fid, time_t t, str d, bool dirty);
        void flush_loop (CLOSURE);
        void load_T (file_id_t id, cbits_t cb, CLOSURE);
        void store_T (file_id_t id, time_t tm, str data, evi_t ev, CLOSURE);
        void remove_T (file_id_t id, evi_t ev, CLOSURE);
        void shutdown_T (evv_t ev, CLOSURE);

        ihash<str, node_t, &node_t::m_filename, &node_t::m_hlink> m_tab;
        tailq<node_t, &node_t::m_qlink> m_queue;
        evv_t::ptr m_shutdown_ev, m_poke_ev;
        tame::lock_table_t<str> m_locks;
        bool m_enabled;
    };

    //-----------------------------------------------------------------------

    class simple_backend_t : public backend_t {
    public:
        simple_backend_t () : backend_t () {}
        void file2str (str fn, evis_t cb);
        virtual void str2file_inner (str f, str s, int mode, bool cf, evi_t cb);
        void remove (str f, evi_t ev);
        void mkdir (str s, int mode, evi_t ev);
        void statvfs (str d, struct statvfs *buf, evi_t ev);
        void stat (str f, struct stat *sb, evi_t ev);

        static int s_file2str (str fn, str *out);
        static int s_remove (str fn);
        static int s_statvfs (str fd, struct statvfs *buf);
        static int s_mkdir (str f, int mode);
        static int s_str2file (str fn, str s, int mode, bool canfail);
        static int s_stat (str fn, struct stat *sb);
    };

    //-----------------------------------------------------------------------

    class simple_fast_backend_t : public simple_backend_t {
    public:
        simple_fast_backend_t () : simple_backend_t () {}
        void str2file_inner (str f, str s, int mode, bool cf, evi_t cb);
        static int s_str2file (str fn, str s, int mode, bool canfail);
    };

    //-----------------------------------------------------------------------

    class thread_backend_t : public backend_t {
    public:
        thread_backend_t (const cfg_t *c);
        ~thread_backend_t ();

        void file2str (str fn, evis_t cb) { file2str_T (fn, cb); }
        void str2file_inner (str f, str s, int m, bool cf, evi_t cb)
        { str2file_inner_T (f, s, m, cf, cb); }

        void remove (str f, evi_t cb) { remove_T (f, cb); }
        void mkdir (str f, int mode, evi_t ev) { mkdir_T (f, mode, ev); }
        void statvfs (str d, struct statvfs *buf, evi_t ev)
        { statvfs_T (d, buf, ev); }
        bool init ();
        void stat (str f, struct stat *sb, evi_t ev) { stat_T (f, sb, ev); }

        typedef enum {
            OP_FILE2STR = 1,
            OP_STR2FILE = 2,
            OP_REMOVE = 3,
            OP_MKDIR = 4,
            OP_STATVFS = 5,
            OP_STAT = 6,
            OP_SHUTDOWN = 7
        } op_t;

        struct in_t {
            op_t _op;
            str _path;
            str _data;
            int _mode;
            bool _can_fail;
        };

        struct out_t {
            int _rc;
            struct statvfs _statvfs;
            time_t _mtime;
            str _data;
            struct stat _stat;
        };

        struct cell_t {
            size_t _id;
#if HAVE_DSDC_PTHREAD
            pthread_t _thread;
#endif
            in_t _in;
            out_t _out;
            int _thread_fd;
            int _main_fd;
            bool _alive;
            const cfg_t *_cfg;
        };

    private:
        void file2str_T (str fn, evis_t cb, CLOSURE);
        void str2file_inner_T (str f, str s, int m, bool c, evi_t e, CLOSURE);
        void remove_T (str f, evi_t ev, CLOSURE);
        void mkdir_T (str f, int mode, evi_t ev, CLOSURE);
        void statvfs_T (str d, struct statvfs *buf, evi_t ev, CLOSURE);
        void stat_T (str f, struct stat *sb, evi_t ev, CLOSURE);

        bool mkthread (size_t i, cell_t *slot);
        void fix_threads (CLOSURE);
        bool fire_off (cell_t *i);
        void return_thread (size_t i);
        void execute (const in_t &in, out_t *out, evb_t ev, CLOSURE);
        void harvest (cell_t *cell, evb_t ev, CLOSURE);
        void grab_thread (ev_sz_t ev, CLOSURE);
        void kill_thread (cell_t *cell);

        const cfg_t *_cfg;
        const size_t _n_threads;
        vec<cell_t> _threads;
        vec<size_t> _ready_q;
        tame::lock_t _lock;
        evv_t::ptr _waiter_ev;
        ptr<bool> _alive;
    };

    //-----------------------------------------------------------------------

    class aiod2_backend_t : public backend_t {
    public:
        aiod2_backend_t (const cfg_t *c);
        ~aiod2_backend_t ();

        void file2str (str fn, evis_t cb) { file2str_T (fn, cb); }
        void str2file_inner (str f, str s, int m, bool c, evi_t cb)
        { str2file_inner_T (f, s, m, c, cb); }

        void remove (str f, evi_t cb) { remove_T (f, cb); }
        void mkdir (str f, int mode, evi_t ev) { mkdir_T (f, mode, ev); }
        void statvfs (str d, struct statvfs *buf, evi_t ev)
        { statvfs_T (d, buf, ev); }
        void stat (str f, struct stat *sb, evi_t ev) { stat_T (f, sb, ev); }
        bool init ();

    private:
        void file2str_T (str fn, evis_t cb, CLOSURE);
        void str2file_inner_T (str f, str s, int mode, bool c, 
                               evi_t cb, CLOSURE);
        void remove_T (str f, evi_t cb, CLOSURE);
        void mkdir_T (str f, int mode, evi_t ev, CLOSURE);
        void statvfs_T (str d, struct statvfs *buf, evi_t ev, CLOSURE);
        void stat_T (str d, struct stat *buf, evi_t ev, CLOSURE);

        const cfg_t *_cfg;
        ptr<aiod2::mgr_t> _aiod;
    };

    //-----------------------------------------------------------------------

    class aiod_backend_t : public backend_t {
    public:
        aiod_backend_t (const cfg_t *c);
        ~aiod_backend_t ();

        void file2str (str fn, evis_t cb) { file2str_T (fn, cb); }
        void str2file (str f, str s, int m, evi_t cb)
        { str2file_T (f, s, m, cb); }

        void remove (str f, evi_t cb) { remove_T (f, cb); }
        void mkdir (str f, int mode, evi_t ev) { mkdir_T (f, mode, ev); }
        void statvfs (str d, struct statvfs *buf, evi_t ev)
        { statvfs_T (d, buf, ev); }

    private:
        void file2str_T (str fn, evis_t cb, CLOSURE);
        void str2file_T (str f, str s, int mode, evi_t cb, CLOSURE);
        void remove_T (str f, evi_t cb, CLOSURE);
        void mkdir_T (str f, int mode, evi_t ev, CLOSURE);
        void statvfs_T (str d, struct statvfs *buf, evi_t ev, CLOSURE);

        const cfg_t *_cfg;
        aiod *_aiod;
    };

    //-----------------------------------------------------------------------

    template<class C>
    class iface_t {
    public:
        iface_t (engine_t *e) : _engine (e) {}

        typedef typename event<int, time_t, ptr<C> >::ref load_cb_t;

        void load (file_id_t id, load_cb_t cb)
        {
            _engine->load (id, wrap (this, &iface_t<C>::load_cb, id, cb));
        }

        void store (file_id_t id, time_t tm, const C &obj, evi_t ev)
        {
            str s;
            str fn = filename (id);
            int ret;
            if (!(s = xdr2str (obj))) {
                warn << "Failed to marshal data struct: " << fn << "\n";
                ret = -EINVAL;
                ev->trigger (ret);
            } else {
                _engine->store (id, tm, s, ev);
            }
        }

        void remove (file_id_t id, evi_t cb) { _engine->remove (id, cb); }
        str filename (file_id_t id) const
        { return _engine->filename (id); }

        void statvfs (struct statvfs *buf, evi_t ev)
        { _engine->statvfs (buf, ev); }

        void set_engine (engine_t *e) { _engine = e; }

    private:

        void load_cb (file_id_t id, load_cb_t cb, int rc, time_t tm, str s)
        {
            ptr<C> ret;
            if (rc == 0) {
                ret = New refcounted<C> ();
                if (!str2xdr (*ret, s)) {
                    str fn = filename (id);
                    warn << "Failed to demarshall data struct: " << fn << "\n";
                    rc = -EINVAL;
                }
            }
            (*cb) (rc, tm, ret);
        }

        engine_t *_engine;
    };

    //-----------------------------------------------------------------------
};

#endif /* _DSDC_FSCACHE_H_ */
