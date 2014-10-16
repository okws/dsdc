// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-
/* $Id$ */

#ifndef __DSDC_CONN_H__
#define __DSDC_CONN_H__

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


#endif
