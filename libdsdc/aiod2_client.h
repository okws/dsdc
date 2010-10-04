// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "async.h"
#include "arpc.h"
#include "tame.h"
#include "dsdc_prot.h"
#include "list.h"
#include "dsdc.h"
#include <sys/statvfs.h>

typedef struct statvfs statvfs_typ_t;
typedef struct stat stat_typ_t;

#pragma once

namespace fscache {
    class cfg_t;
};

namespace aiod2 {

    class mgr_t;

    //-----------------------------------------------------------------------

    struct remote_t {
        remote_t () {}
        remote_t (str h, int p) : m_host (h), m_port (p) {}
        bool parse (str in, int defport = 0);
        str to_str () { return strbuf ("%s:%d", m_host.cstr (), m_port); }
        str m_host;
        int m_port;
    };

    //-----------------------------------------------------------------------

    struct remotes_t : public vec<remote_t> {
        bool parse (str in, int defport = 0);
        static ptr<remotes_t> alloc (str in, int defport = 0);
    };

    //------------------------------------------------------------

    class base_client_t : public virtual refcount {
    public:
        base_client_t (mgr_t *m);
        virtual void launch (evb_t ev, CLOSURE) = 0;
        void get_aclnt (event<ptr<aclnt> >::ref ev, CLOSURE);
        void kill ();
    protected:
        void relaunch (CLOSURE);
        void launch_client();
        void trigger_waiter ();
        void eofcb ();
        mgr_t *m_mgr;
        bool m_killed;
        evv_t::ptr m_waiter;
        ptr<aclnt> m_cli;
        ptr<axprt> m_x;
    };

    //------------------------------------------------------------

    class local_client_t : public base_client_t {
    public:
        local_client_t (mgr_t *m) : base_client_t (m) {}
        ~local_client_t () {}
        void launch (evb_t ev, CLOSURE);
        static str prog_path ();
    protected:
    };

    //------------------------------------------------------------

    class remote_client_t : public base_client_t {
    public:
        remote_client_t (mgr_t *m, remote_t r) 
            : base_client_t (m), m_remote (r) {}
        ~remote_client_t () {}
        void launch (evb_t ev, CLOSURE);
    private:
        remote_t m_remote;
    };

    //------------------------------------------------------------

    typedef enum {
        WO_NONE = 0x0,
        WO_SYNC = 0x1,
        WO_CANFAIL = 0x2,
        WO_ATOMIC = 0x4
    } write_opts_t;

    //------------------------------------------------------------

    
    class mgr_t : public virtual refcount {
    public:
        mgr_t (const fscache::cfg_t *cfg),
        ~mgr_t ();
        void kill ();
        void init (evb_t ev, CLOSURE);
        void file2str (str fn, evis_t cb, CLOSURE);
        void str2file (str f, str s, int flags, int mode, write_opts_t opts,
                       evi_t ev, CLOSURE);
        void remove (str f, evi_t ev, CLOSURE);
        void mkdir (str s, int mode, evi_t cb, CLOSURE);
        void statvfs (str d, statvfs_typ_t *buf, evi_t ev, CLOSURE);
        void stat (str f, stat_typ_t *sb, evi_t ev, CLOSURE);
        void glob (str d, str p, vec<str> *out, evi_t ev, CLOSURE);
        void set_ready (ptr<base_client_t> c);
        size_t packet_size () const { return m_packet_size; }
        ptr<base_client_t> alloc_client (size_t i);
    private:
        void get_ready (event<int, ptr<base_client_t>, ptr<aclnt> >::ref ev, 
                        CLOSURE);
        void get_ready_client (event<ptr<base_client_t> >::ref ev, CLOSURE);
        vec<ptr<base_client_t> > m_clients;
        vec<ptr<base_client_t> > m_ready;
        vec<evv_t::ptr> m_waiters;
        bool m_killed;
        size_t m_n_procs;
        size_t m_packet_size;
        ptr<remotes_t> m_remotes;
        const fscache::cfg_t *m_cfg;
    };
    //------------------------------------------------------------
    
};
