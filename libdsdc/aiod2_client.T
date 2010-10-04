// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "fscache.h"
#include "aiod2_client.h"
#include "rxx.h"

extern char ** environ;

namespace aiod2 {
#if 0
}
#endif
    
//-----------------------------------------------------------------------

bool
remote_t::parse (str s, int defport)
{
    m_port = defport;
    return (parse_hn (s, &m_host, &m_port) && m_port);
}

//-----------------------------------------------------------------------

bool
remotes_t::parse (str in, int defport)
{
    static rxx x ("\\s*,\\s*");
    vec<str> v;
    split (&v, x, in);
    bool ret = true;
    for (size_t i = 0; i < v.size () && ret; i++) {
        if (!push_back ().parse (v[i], defport)) {
            ret = false;
        }
    }
    return ret;
}

//-----------------------------------------------------------------------

mgr_t::mgr_t (const fscache::cfg_t *c)
  : m_killed (false),
    m_n_procs (c->n_aiods ()), 
    m_packet_size (c->max_packet_size ()),
    m_remotes (c->aiod2_remotes ()),
    m_cfg (c) {}

//-----------------------------------------------------------------------

mgr_t::~mgr_t () { kill (); }

//-----------------------------------------------------------------------

base_client_t::base_client_t (mgr_t *m) : m_mgr (m), m_killed (false) {}

//-----------------------------------------------------------------------

void
base_client_t::trigger_waiter ()
{
    if (m_waiter) {
        evv_t::ptr tmp = m_waiter;
        m_waiter = NULL;
        tmp->trigger ();
    }
}

//-----------------------------------------------------------------------

void
base_client_t::kill ()
{
    if (m_cli) { 
        m_cli->seteofcb (NULL); 
        m_cli = NULL;
        m_x = NULL;
    }
    m_killed = true;
    trigger_waiter ();
}

//-----------------------------------------------------------------------

tamed void
base_client_t::get_aclnt (event<ptr<aclnt> >::ref ev)
{
    tvars {
        ptr<aclnt> ret;
    }

    while (!(ret = m_cli) && !m_killed) {
        twait { m_waiter = mkevent (); }
    }
    ev->trigger (ret);
}

//-----------------------------------------------------------------------

ptr<base_client_t>
mgr_t::alloc_client (size_t i)
{
    ptr<base_client_t> ret;
    size_t n;
    if (m_remotes && (n = m_remotes->size ())) {
        const remote_t &r = (*m_remotes)[i % n];
        ret = New refcounted<remote_client_t> (this, r);
    } else {
        ret = New refcounted<local_client_t> (this);
    }
    return ret;
}

//-----------------------------------------------------------------------

tamed void
mgr_t::init (evb_t ev)
{
    tvars {
        size_t i;
        ptr<base_client_t> c;
        bool ok (true);
    }

    for (i = 0; ok && i < m_n_procs; i++) {
        c = alloc_client (i);
        twait { c->launch (mkevent (ok)); }
        if (!ok) {
            warn ("aiod2 error: failed to launch client\n");
        } else {
            m_clients.push_back (c);
            set_ready (c);
        }
    }
    ev->trigger (ok);
}

//-----------------------------------------------------------------------

tamed void
mgr_t::get_ready_client (event<ptr<base_client_t> >::ref ev)
{
    tvars {
        ptr<base_client_t> cli;
    }

    while (!m_ready.size () && !m_killed) {
        twait { m_waiters.push_back (mkevent ()); }
    }
    if (m_ready.size ()) {
        cli = m_ready.pop_back ();
    }
    ev->trigger (cli);
}

//-----------------------------------------------------------------------

void
mgr_t::set_ready (ptr<base_client_t> c)
{
    if (c) {
        m_ready.push_back (c);
        if (m_waiters.size ()) {
            evv_t::ptr v = m_waiters.pop_front ();
            v->trigger ();
        }
    }
}

//-----------------------------------------------------------------------

str
local_client_t::prog_path ()
{
    strbuf b;
    b << DSDC_EXEC_BINDIR << "/aiod2";
    return b;
}

//-----------------------------------------------------------------------

tamed void
mgr_t::get_ready (event<int, ptr<base_client_t>, ptr<aclnt> >::ref ev)
{
    tvars {
        ptr<base_client_t> c;
        ptr<aclnt> ret;
        int rc;
    }
    twait { get_ready_client (mkevent (c)); }
    if (c) {
        twait { c->get_aclnt (mkevent (ret)); }
    }
    rc = ret ? 0 : ESHUTDOWN;
    ev->trigger (rc, c, ret);
}

//-----------------------------------------------------------------------

void
mgr_t::kill ()
{
    if (!m_killed) { 
        m_killed = true;
        for (size_t i = 0; i < m_clients.size (); i++) {
            m_clients[i]->kill ();
        }
    }
}

//-----------------------------------------------------------------------

tamed void
mgr_t::file2str (str fn, evis_t ev)
{
    tvars {
        holdvar ptr<mgr_t> hold (mkref (_self));
        aiod_file_to_str_res_t res;
        aiod_file_t arg;
        ptr<base_client_t> cli;
        ptr<aclnt> acli;
        clnt_stat err;
        str dat;
        int rc (0);
    }

    twait { get_ready (mkevent (rc, cli, acli)); }
    if (acli) {
        arg = fn;
        
        twait { 
            RPC::aiod_prog_2::
                aiod2_file_to_str (acli, arg, &res, mkevent (err));
        }
        if (err) {
            warn << "aiod2 RPC error: " << err << "\n";
            rc = ENETDOWN;
        } else if (res.code) {
            rc = res.code;
        } else {
            mstr m (res.data->size ());
            memcpy (m.cstr (), res.data->base (), res.data->size ());
            dat = m;
        }
    }
    set_ready (cli);
    ev->trigger (rc, dat);
}

//-----------------------------------------------------------------------

tamed void
mgr_t::remove (str f, evi_t ev)
{
    tvars {
        holdvar ptr<mgr_t> hold (mkref (_self));
        aiod_file_t arg;
        ptr<base_client_t> cli;
        ptr<aclnt> acli;
        clnt_stat err;
        int rc (0);
    }

    twait { get_ready (mkevent (rc, cli, acli)); }
    if (acli) {
        arg = f;
        twait { 
            RPC::aiod_prog_2::
                aiod2_remove (acli, arg, &rc, mkevent (err));
        }
        if (err) {
            warn << "aiod2 RPC error: " << err << "\n";
            rc = ENETDOWN;
        }
    }
    set_ready (cli);
    ev->trigger (rc);
}

//-----------------------------------------------------------------------

tamed void
mgr_t::mkdir (str f, int mode, evi_t ev)
{
    tvars {
        holdvar ptr<mgr_t> hold (mkref (_self));
        aiod_mkdir_arg_t arg;
        ptr<base_client_t> cli;
        ptr<aclnt> acli;
        clnt_stat err;
        int rc (0);
    }

    twait { get_ready (mkevent (rc, cli, acli)); }
    if (acli) {
        arg.file = f;
        arg.mode = mode;

        twait { 
            RPC::aiod_prog_2::
                aiod2_mkdir (acli, arg, &rc, mkevent (err));
        }
        if (err) {
            warn << "aiod2 RPC error: " << err << "\n";
            rc = ENETDOWN;
        }
    }
    set_ready (cli);
    ev->trigger (rc);
}

//-----------------------------------------------------------------------

tamed void
mgr_t::stat (str d, stat_typ_t *out, evi_t ev)
{
    tvars {
        holdvar ptr<mgr_t> hold (mkref (_self));
        aiod_file_t arg;
        ptr<base_client_t> cli;
        ptr<aclnt> acli;
        clnt_stat err;
        int rc (0);
        aiod_stat_res_t res;
    }

    twait { get_ready (mkevent (rc, cli, acli)); }
    if (acli) {
        arg = d;

        twait { 
            RPC::aiod_prog_2::aiod2_stat (acli, arg, &res, mkevent (err));
        }
        if (err) {
            warn << "aiod2 RPC error: " << err << "\n";
            rc = ENETDOWN;
        } else if (res.code) {
            rc = res.code; 
        } else {
           
#define A(field) \
            out->st_##field = res.stat->aiod_st_##field
            
            A(dev);
            A(ino);
            A(mode);
            A(nlink);
            A(uid);
            A(gid);
            A(rdev);
            A(size);
            A(blksize);
            A(blocks);
            A(atime);
            A(mtime);
            A(ctime);
#undef A
            rc = 0;

        }
    }
    set_ready (cli);
    ev->trigger (rc);
}

//-----------------------------------------------------------------------

tamed void
mgr_t::statvfs (str d, statvfs_typ_t *out, evi_t ev)
{
    tvars {
        holdvar ptr<mgr_t> hold (mkref (_self));
        aiod_file_t arg;
        ptr<base_client_t> cli;
        ptr<aclnt> acli;
        clnt_stat err;
        int rc (0);
        aiod_statvfs_res_t res;
    }

    twait { get_ready (mkevent (rc, cli, acli)); }
    if (acli) {
        arg = d;

        twait { 
            RPC::aiod_prog_2::
                aiod2_statvfs (acli, arg, &res, mkevent (err));
        }
        if (err) {
            warn << "aiod2 RPC error: " << err << "\n";
            rc = ENETDOWN;
        } else if (res.code) {
            rc = res.code; 
        } else {
           
#define A(field) \
            out->f_##field = res.stat->aiod_f_##field

            A(bsize);
            A(bsize);
            A(frsize);
            A(blocks);
            A(bfree);
            A(bavail);
            A(files);
            A(ffree);
            A(favail);
            A(fsid);
            A(flag);
            A(namemax);
#undef A
            rc = 0;

        }
    }
    set_ready (cli);
    ev->trigger (rc);
}

//-----------------------------------------------------------------------

tamed void
mgr_t::glob (str d, str p, vec<str> *out, evi_t ev)
{
    tvars {
        holdvar ptr<mgr_t> hold (mkref (_self));
        aiod_glob_arg_t arg;
        aiod_glob_res_t res;
        ptr<base_client_t> cli;
        ptr<aclnt> acli;
        clnt_stat err;
        int rc (0);
    }

    twait { get_ready (mkevent (rc, cli, acli)); }
    if (acli) {
        arg.dir = d;
        arg.pattern = p;
        twait { RPC::aiod_prog_2::aiod2_glob (acli, arg, &res, mkevent (err)); }
        if (err) {
            warn << "aiod2 RPC error: " << err << "\n";
            rc = ENETDOWN;
        } else if (res.code == 0) {
            for (size_t i = 0; i < res.files->size (); i++) {
                out->push_back ((*res.files)[i]);
            }
        }
    }
    ev->trigger (rc);
}


//-----------------------------------------------------------------------

tamed void
mgr_t::str2file (str f, str d, int flags, int mode, write_opts_t opts,
                 evi_t ev)
{
    tvars {
        holdvar ptr<mgr_t> hold (mkref (_self));
        aiod_str_to_file_arg_t arg;
        ptr<base_client_t> cli;
        ptr<aclnt> acli;
        clnt_stat err;
        int rc (0);
    }

    twait { get_ready (mkevent (rc, cli, acli)); }
    if (acli) {
        arg.file = f;
        arg.data.setsize (d.len ());
        memcpy (arg.data.base (), d.cstr (), d.len ());

        arg.flags = flags;
        arg.mode = mode;
        arg.sync = (opts & WO_SYNC);
        arg.canfail = (opts & WO_CANFAIL);
        arg.atomic = (opts & WO_ATOMIC);

        twait { 
            RPC::aiod_prog_2::
                aiod2_str_to_file (acli, arg, &rc, mkevent (err));
        }
        if (err) {
            warn << "aiod2 RPC error: " << err << "\n";
            rc = ENETDOWN;
        }
    }
    set_ready (cli);
    ev->trigger (rc);
}

//-----------------------------------------------------------------------

void
base_client_t::eofcb ()
{
    warn << "aiod2 error: helper proc crashed\n";
    m_x = NULL;
    m_cli = NULL;
    relaunch ();
}

//-----------------------------------------------------------------------

tamed void
base_client_t::relaunch ()
{
    tvars {
        bool ok (false);
    }

    while (!ok && !m_killed) {
        twait { launch (mkevent (ok)); }
        if (!ok && !m_killed) {
            twait { delaycb (3, 0, mkevent ()); }
        }
    }
}

//-----------------------------------------------------------------------

void
base_client_t::launch_client ()
{
    m_cli = aclnt::alloc (m_x, aiod_prog_2);
    m_cli->seteofcb (wrap (mkref (this), &local_client_t::eofcb));
    trigger_waiter ();
}

//-----------------------------------------------------------------------

void
local_client_t::launch (evb_t ev, ptr<closure_t> dummy)
{
    str p;
    vec<str> args;
    bool ok (true);
    size_t ps = m_mgr->packet_size ();

    p = prog_path ();
    args.push_back (p);
    args.push_back ("-s");
    args.push_back (strbuf ("%zu", ps));
    if ((m_x = axprt_unix_spawnv (p, args, ps, NULL, environ))) {
        launch_client ();
    } else {
        ok = false;
    }
    ev->trigger (ok);
}

//-----------------------------------------------------------------------

tamed void
remote_client_t::launch (evb_t ev)
{
    tvars {
        int fd;
    }
    twait { tcpconnect (m_remote.m_host, m_remote.m_port, mkevent (fd)); }
    if (fd > 0) {
        m_x = axprt_stream::alloc (fd, m_mgr->packet_size ());
        launch_client ();
    } else {
        str s = m_remote.to_str ();
        warn << "XX connection to host " << s << " failed\n";
    }
    ev->trigger (fd >= 0);
}

//-----------------------------------------------------------------------

};
