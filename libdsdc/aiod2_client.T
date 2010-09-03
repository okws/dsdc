// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "aiod2_client.h"

namespace aiod2 {
#if 0
}
#endif

//-----------------------------------------------------------------------

mgr_t::mgr_t () {}

//-----------------------------------------------------------------------

client_t::client_t (mgr_t *m) : m_mgr (m), m_killed (false) {}

//-----------------------------------------------------------------------

void
client_t::kill ()
{
    if (m_cli) { 
        m_cli->seteofcb (NULL); 
        m_cli = NULL;
    }
    m_killed = true;
    if (m_waiter) {
        evv_t::ptr tmp = m_waiter;
        m_waiter = NULL;
        tmp->trigger ();
    }
}

//-----------------------------------------------------------------------

tamed void
client_t::get_aclnt (event<ptr<aclnt> >::ref ev)
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

tamed void
mgr_t::init (size_t n_procs, evb_t ev)
{
    tvars {
        size_t i;
        ptr<client_t> c;
        bool ok;
    }
    for (i = 0; ok && i < n_procs; i++) {
        c = New refcounted<client_t> (this);
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
mgr_t::get_ready_client (event<ptr<client_t> >::ref ev)
{
    tvars {
        ptr<client_t> cli;
    }

    while (!m_ready.size () && !m_killed) {
        twait { m_waiters.push_back (mkevent ()); }
    }
    if (!m_killed) {
        cli = m_ready.pop_back ();
    }
    ev->trigger (cli);
}

//-----------------------------------------------------------------------

void
mgr_t::set_ready (ptr<client_t> c)
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
client_t::prog_path ()
{
    strbuf b;
    b << DSDC_EXEC_BINDIR << "/aiod2";
    return b;
}

//-----------------------------------------------------------------------

tamed void
mgr_t::get_ready (event<int, ptr<client_t>, ptr<aclnt> >::ref ev)
{
    tvars {
        ptr<client_t> c;
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
    m_killed = true;
    for (size_t i = 0; i < m_clients.size (); i++) {
        m_clients[i]->kill ();
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
        ptr<client_t> cli;
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
mgr_t::str2file (str f, str d, int flags, int mode, write_opts_t opts,
                 evi_t ev)
{
    tvars {
        holdvar ptr<mgr_t> hold (mkref (_self));
        aiod_str_to_file_arg_t arg;
        ptr<client_t> cli;
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
        arg.sync = (opts & AIOD2_WRITE_SYNC);
        arg.canfail = (opts & AIOD2_WRITE_CANFAIL);
        arg.atomic = (opts & AIOD2_WRITE_ATOMIC);

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
client_t::eofcb ()
{
    warn << "aiod2 error: helper proc crashed\n";
    m_x = NULL;
    m_cli = NULL;
    relaunch ();
}

//-----------------------------------------------------------------------

tamed void
client_t::relaunch ()
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

tamed void
client_t::launch (evb_t ev)
{
    tvars {
        str p;
        vec<str> args;
        bool ok (true);
    }
    p = prog_path ();
    args.push_back (p);
    m_x = axprt_unix_spawnv (p, args, dsdc_packet_sz);
    if (m_x) {
        m_cli = aclnt::alloc (m_x, aiod_prog_2);
        m_cli->seteofcb (wrap (mkref (this), &client_t::eofcb));
    } else {
        ok = false;
    }
    ev->trigger (ok);
}

//-----------------------------------------------------------------------


//-----------------------------------------------------------------------


};
