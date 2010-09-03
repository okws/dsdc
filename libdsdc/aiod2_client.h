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

namespace aiod2 {

    class mgr_t;

    //------------------------------------------------------------

    class client_t : public virtual refcount {
    public:
        client_t (mgr_t *m);
        ~client_t () {}
        bool launch ();
        void get_aclnt (event<ptr<aclnt> >::ref ev, CLOSURE);
        static str prog_path ();
        void eofcb ();
        void kill ();
    private:
        void relaunch (CLOSURE);
        mgr_t *m_mgr;
        ptr<axprt_unix> m_x;
        ptr<aclnt> m_cli;
        evv_t::ptr m_waiter;
        bool m_killed;
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
        mgr_t (size_t n);
        ~mgr_t ();
        void kill ();
        bool init ();
        void file2str (str fn, evis_t cb, CLOSURE);
        void str2file (str f, str s, int flags, int mode, write_opts_t opts,
                       evi_t ev, CLOSURE);
        void remove (str f, evi_t ev, CLOSURE);
        void mkdir (str s, int mode, evi_t cb, CLOSURE);
        void statvfs (str d, statvfs_typ_t *buf, evi_t ev, CLOSURE);
        void stat (str f, stat_typ_t *sb, evi_t ev, CLOSURE);
        void set_ready (ptr<client_t> c);
    private:
        void get_ready (event<int, ptr<client_t>, ptr<aclnt> >::ref ev, 
                        CLOSURE);
        void get_ready_client (event<ptr<client_t> >::ref ev, CLOSURE);
        vec<ptr<client_t> > m_clients;
        vec<ptr<client_t> > m_ready;
        vec<evv_t::ptr> m_waiters;
        bool m_killed;
        size_t m_n_procs;
    };
    //------------------------------------------------------------
    
};
