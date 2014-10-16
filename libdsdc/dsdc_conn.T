// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "arpc.h"
#include "tame.h"
#include "dsdc_conn.h"

//-----------------------------------------------------------------------------

tamed void
aclnt_connection_t::call(u_int32_t procno, const void *in, void *out, 
                         aclnt_cb cb) {
    m_ac->call(procno, in, out, cb);
}

//-----------------------------------------------------------------------------

tamed void
aclnt_connection_t::timedcall(time_t sec, long nsec, u_int32_t procno, 
                              const void *in, void *out, aclnt_cb cb) {
    m_ac->timedcall(sec, nsec, procno, in, out, cb);
}

//-----------------------------------------------------------------------------

