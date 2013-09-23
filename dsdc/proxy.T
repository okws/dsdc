// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "dsdc_proxy.h"
#include "rpc_stats.h"
#include "okconst.h"

//-----------------------------------------------------------------------------

dsdc_proxy_client_t::dsdc_proxy_client_t(dsdc_proxy_t* m, int fd, str h) {
    tcp_nodelay(fd);
    m_proxy = m;
    m_hostname = h;
    m_x = axprt_stream::alloc(fd, dsdc_packet_sz);
    m_asrv = asrv::alloc(m_x, dsdc_prog_1,
                         wrap(this, &dsdc_proxy_client_t::dispatch));
}

//-----------------------------------------------------------------------------

dsdc_proxy_client_t* 
dsdc_proxy_client_t::alloc(dsdc_proxy_t* m, int fd, str h) {
    return New dsdc_proxy_client_t(m, fd, h);
}

//-----------------------------------------------------------------------------

void
dsdc_proxy_client_t::dispatch(svccb* sbp) {
    if (!sbp) {
        warn << "client: " << m_hostname << " gave EOF\n"; 
        delete this;
        return;
    }

    switch (sbp->proc ()) {
    case DSDC_GET:
    case DSDC_GET2:
    case DSDC_GET3:
        m_proxy->handle_get (sbp);
        break;
    case DSDC_REMOVE:
    case DSDC_REMOVE3:
        m_proxy->handle_remove (sbp);
        break;
    case DSDC_PUT:
    case DSDC_PUT3:
    case DSDC_PUT4:
        m_proxy->handle_put (sbp);
        break;
    default:
        sbp->reject (PROC_UNAVAIL);
        break;
    }
}

//-----------------------------------------------------------------------

bool
dsdc_proxy_t::init () {
    m_lfd = inetsocket(SOCK_STREAM, m_port);
    if (m_lfd < 0) {
        warn ("in proxy init: %m\n");
        return false;
    }
    close_on_exec(m_lfd);
    listen(m_lfd, 256);
    fdcb(m_lfd, selread, wrap (this, &dsdc_proxy_t::new_connection));
    m_cli->init(NULL);

    get_rpc_stats()
        .set_active(true)
        .set_interval(ok_amt_rpc_stats_interval);

    return true;
}

//-----------------------------------------------------------------------

void
dsdc_proxy_t::new_connection () {
    sockaddr_in sin;
    bzero (&sin, sizeof (sin));
    socklen_t sinlen = sizeof (sin);
    int nfd = accept(m_lfd, reinterpret_cast<sockaddr *> (&sin), &sinlen);
    if (nfd >= 0) {
        strbuf hn ("%s:%d", inet_ntoa (sin.sin_addr), sin.sin_port);
        warn << "accepting connection from " << hn << "\n";

        // Note that we have this client, and just let it do its own
        // thing. alloc() will call refcount_inc(), meaning this thing
        // will stay around **at least** until dsdcm_client_t::release()
        // is called on an EOF.
        dsdc_proxy_client_t::alloc(this, nfd, hn);

    } else if (errno != EAGAIN)
        warn ("accept failed: %m\n");
}

//-----------------------------------------------------------------------------

void
dsdc_proxy_t::add_master(const str& m, int p) {
   m_cli->add_master(m, p); 
}

//-----------------------------------------------------------------------------

tamed void
dsdc_proxy_t::handle_get(svccb* sbp) {
   
    tvars {
        ptr<dsdc_get_res_t> res;
        dsdc_req_t* a2;
        dsdc_get3_arg_t* a3;
        ptr<dsdc_key_t> key;
        dsdc::annotation::base_t *an;
        int time_to_expire;
        timespec ts_start;
    }

    ts_start = sfs_get_tsnow ();
    switch (sbp->proc()) {
    case DSDC_GET:
        key = New refcounted<dsdc_key_t>(*(sbp->Xtmpl getarg<dsdc_get_arg_t>())); 
        twait { m_cli->get(key, mkevent(res)); }
        break;
    case DSDC_GET2:
        a2 = sbp->Xtmpl getarg<dsdc_req_t>();
        key = New refcounted<dsdc_key_t>(a2->key);
        time_to_expire = a2->time_to_expire;

        twait { m_cli->get(key, mkevent(res), false, time_to_expire, NULL); }
        break;
    case DSDC_GET3:
        a3 = sbp->Xtmpl getarg<dsdc_get3_arg_t>();
        key = New refcounted<dsdc_key_t>(a3->key);
        time_to_expire = a3->time_to_expire;
        an = dsdc::stats::collector()->alloc(a3->annotation);
    
        twait { m_cli->get(key, mkevent(res), false, time_to_expire, an); }
        break;
    };

    if (!res) {
        res = New refcounted<dsdc_get_res_t>();
        res->set_status(DSDC_RPC_ERROR);
    }
    get_rpc_stats().end_call (sbp->prog(), sbp->vers(), sbp->prog(), ts_start);

    sbp->reply(res);
}

//-----------------------------------------------------------------------------

tamed void
dsdc_proxy_t::handle_remove(svccb* sbp) {

    tvars {
        ptr<dsdc_remove3_arg_t> arg;
        ptr<dsdc_key_t> key;
        dsdc_res_t res;
        int rc;
        timespec ts_start;
    }

    ts_start = sfs_get_tsnow ();
    switch (sbp->proc()) {
    case DSDC_REMOVE:
        key = New refcounted<dsdc_key_t>(*(sbp->Xtmpl getarg<dsdc_key_t>()));
        twait { m_cli->remove(key, mkevent(rc)); }
        break;
    case DSDC_REMOVE3:
        arg = New refcounted<dsdc_remove3_arg_t>
            (*(sbp->Xtmpl getarg<dsdc_remove3_arg_t>()));
        twait { m_cli->remove(arg, mkevent(rc)); }
        break;
    };

    get_rpc_stats().end_call (sbp->prog(), sbp->vers(), sbp->prog(), ts_start);
    rc = dsdc_res_t(rc);
    sbp->replyref(res);    
}

//-----------------------------------------------------------------------------

tamed void
dsdc_proxy_t::handle_put(svccb* sbp) {

    tvars {
        int rc;
        dsdc_res_t res;
        ptr<dsdc_put_arg_t> a1;
        ptr<dsdc_put4_arg_t> a4;
        ptr<dsdc_put3_arg_t> a3;
        timespec ts_start;
    }

    ts_start = sfs_get_tsnow ();
    switch (sbp->proc()) {
    case DSDC_PUT:
        a1 = New refcounted<dsdc_put_arg_t>(*(sbp->Xtmpl getarg<dsdc_put_arg_t>()));
        twait { m_cli->put(a1, mkevent(rc)); }
        break;
    case DSDC_PUT3:
        a3 = New refcounted<dsdc_put3_arg_t>(*(sbp->Xtmpl getarg<dsdc_put3_arg_t>()));
        twait { m_cli->put(a3, mkevent(rc)); }
        break;
    case DSDC_PUT4:
        a4 = New refcounted<dsdc_put4_arg_t>(*(sbp->Xtmpl getarg<dsdc_put4_arg_t>()));
        twait { m_cli->put(a4, mkevent(rc)); }
        break;
    };

    get_rpc_stats().end_call (sbp->prog(), sbp->vers(), sbp->prog(), ts_start);
    res = dsdc_res_t(rc);
    sbp->replyref(res);
}

//-----------------------------------------------------------------------------

