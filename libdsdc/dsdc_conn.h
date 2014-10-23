// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-
/* $Id$ */

#ifndef __DSDC_CONN_H__
#define __DSDC_CONN_H__

#include "redis.h"
#include "dsdc_prot.h"

//-----------------------------------------------------------------------------

class connection_t {
public:
    virtual void call(u_int32_t procno, const void *in, void *out, aclnt_cb cb,
                      CLOSURE) = 0;
    virtual void timedcall(time_t secs, long nsec, u_int32_t procno, 
                           const void *in, void *out, aclnt_cb cb, CLOSURE) = 0;
};

//-----------------------------------------------------------------------------

typedef callback<void, ptr<connection_t>>::ref conn_cb_t;

//-----------------------------------------------------------------------------

class aclnt_connection_t : public connection_t {
public:

    aclnt_connection_t(ptr<aclnt> ac) : m_ac(ac) { }

    virtual void call(u_int32_t procno, const void *in, void *out, aclnt_cb cb,
                      CLOSURE) override; 
    virtual void timedcall(time_t secs, long nsec, u_int32_t procno, 
                           const void *in, void *out, aclnt_cb cb, 
                           CLOSURE) override;

protected:

    ptr<aclnt> m_ac;
};

//-----------------------------------------------------------------------------

class redis_connection_t : public connection_t {
public:

    redis_connection_t();

    void connect(str host, int port, evb_t ev, CLOSURE);

    virtual void call(u_int32_t procno, const void *in, void *out, aclnt_cb cb,
                      CLOSURE) override; 
    virtual void timedcall(time_t secs, long nsec, u_int32_t procno, 
                           const void *in, void *out, aclnt_cb cb, 
                           CLOSURE) override;

    bool is_connected() { return m_redis.isConnected(); }

protected:

    void handle_get3(const void* in, void* out, evb_t ev, CLOSURE);
    void handle_put4(const void* in, void* out, evb_t ev, CLOSURE);
    void handle_put3(const void* in, void* out, evb_t ev, CLOSURE);
    void handle_remove3(const void* in, void* out, evb_t ev, CLOSURE);

    void handle_put(void* out, const dsdc_key_t& key,
                    const dsdc_obj_t& obj,
                    dsdc_cksum_t* cksum, evb_t, CLOSURE);

    void make_dict(pub3::obj_t outdict, pub3::obj_t list);

    RedisCli m_redis; 

    static const char* m_lua_get;
    static str m_lua_get_sha1;
    static const char* m_lua_put;
    static str m_lua_put_sha1;

};

//-----------------------------------------------------------------------------


#endif
