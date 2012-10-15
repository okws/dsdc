// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "dsdc_prot.h"
#include "dsdc_util.h"
#include "dsdc_const.h"
#include "dsdc.h"

#include "itree.h"
#include "ihash.h"
#include "async.h"
#include "arpc.h"
#include "tame.h"

//-----------------------------------------------------------------------------

class dsdc_proxy_t;

//-----------------------------------------------------------------------------

class dsdc_proxy_client_t {
public:

    dsdc_proxy_client_t(dsdc_proxy_t* m, int fd, str h);
    static dsdc_proxy_client_t* alloc(dsdc_proxy_t *m, int fd, str h);

    void dispatch(svccb* sbp);

protected:

    dsdc_proxy_t* m_proxy;
    int m_fd;
    ptr<axprt> m_x;
    ptr<asrv> m_asrv;
    str m_hostname;
};

//-----------------------------------------------------------------------------

class dsdc_proxy_t : public dsdc_app_t {
public:

    dsdc_proxy_t(int p = -1) :
        m_port(p > 0 ? p : dsdc_proxy_port), m_lfd(-1) {
        m_cli = New refcounted<dsdc_smartcli_t>();    
    }

    bool init();
    void new_connection();
    
    void handle_get (svccb *b, CLOSURE);
    void handle_remove (svccb *b, CLOSURE);
    void handle_put (svccb *b, CLOSURE);

    void add_master(const str& m, int port);

protected:

    int m_port;
    int m_lfd;

    ptr<dsdc_smartcli_t> m_cli;
};

//-----------------------------------------------------------------------------

