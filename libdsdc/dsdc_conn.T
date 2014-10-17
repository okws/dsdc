// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "arpc.h"
#include "tame.h"
#include "dsdc_conn.h"
#include "pub3obj.h"
#include "dsdc.h"
#include "dsdc_util.h"

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

tamed void
redis_connection_t::connect(str host, int port, evb_t ev) {

    tvars {
        bool ok;
    }

    twait { m_redis.connect(host, port, mkevent(ok)); }

    ev->trigger(ok);
}

//-----------------------------------------------------------------------------

tamed void
redis_connection_t::call(u_int32_t procno, const void *in, void *out, 
                         aclnt_cb cb) {


    tvars {
        bool ok(false);
    }

    switch (procno) {
    case DSDC_GET3:
        twait { handle_get3(in, out, mkevent(ok)); }
        break;
    case DSDC_PUT4:
        twait { handle_put4(in, out, mkevent(ok)); }
        break;
    case DSDC_PUT3:
        twait { handle_put3(in, out, mkevent(ok)); }
        break;
    case DSDC_REMOVE3:
        twait { handle_remove3(in, out, mkevent(ok)); }
        break;
    default:
        warn << "dsdc_panic: redis_connection_t::call(): unknown procedure: "
             << procno << "\n";
    };

    cb((ok) ? RPC_SUCCESS : RPC_FAILED);
};

//-----------------------------------------------------------------------------

void
redis_connection_t::make_dict(pub3::obj_t outdict, pub3::obj_t list) {
    for (size_t i = 0; i < list.size(); i += 2) {
        outdict(list[i].to_str()) = list[i+1];
    }
}

//-----------------------------------------------------------------------------

tamed void
redis_connection_t::handle_get3(const void* in, void* out, evb_t ev) {

    tvars {
        const dsdc_get3_arg_t* arg;
        redis_res_t val_res;
        dsdc_get_res_t* dsdc_res;
        bool ok(true);
        int insert_time;
        int time_to_expire;
        pub3::obj_dict_t outdict;

        str res_str;
    }

    arg  = (const dsdc_get3_arg_t*) in;
    dsdc_res = (dsdc_get_res_t*) out;
    time_to_expire = arg->time_to_expire;

    twait {
        m_redis.runCmd({ std::make_pair("HGETALL", 7), 
                         std::make_pair(arg->key.base(), arg->key.size()) }, 
                       mkevent(val_res));
    }
    
    // MM: All of this can be done by a Lua script on the Redis server
    (*dsdc_res).set_status(DSDC_OK);
    if (!val_res.is_err()) {
        
        if (val_res.obj().isnull()) {
            (*dsdc_res).set_status(DSDC_NOTFOUND);
            ev->trigger(ok);
            return;
        }

        make_dict(outdict, val_res.obj());
        res_str = outdict("value").to_str();

        // Check expiration
        if (time_to_expire) {
            insert_time = outdict("insert").to_int();
            if ((sfs_get_timenow() - time_to_expire) >= insert_time) {
                (*dsdc_res).set_status(DSDC_EXPIRED);
            } else {
                *((*dsdc_res).obj) = res_str;
            }
        } else {
            *((*dsdc_res).obj) = res_str;
        }

    } else {
        ok = false;
        (*dsdc_res).set_status(DSDC_RPC_ERROR);
        *((*dsdc_res).err) = RPC_FAILED;
    }

    ev->trigger(ok);
}

//-----------------------------------------------------------------------------

tamed void
redis_connection_t::handle_put4(const void* in, void* out, evb_t ev) {

    const dsdc_put4_arg_t* arg;
    arg = (const dsdc_put4_arg_t*) in;

    handle_put(out, arg->key, arg->obj, arg->checksum, ev);
}

//-----------------------------------------------------------------------------

tamed void
redis_connection_t::handle_put3(const void* in, void* out, evb_t ev) {

    const dsdc_put3_arg_t* arg;
    arg = (const dsdc_put3_arg_t*) in;

    handle_put(out, arg->key, arg->obj, nullptr, ev); 
}

//-----------------------------------------------------------------------------

tamed void
redis_connection_t::handle_put(void* out, const dsdc_key_t& key,
                               const dsdc_obj_t& obj,
                               dsdc_cksum_t* cksum, evb_t ev) {

    tvars {
        dsdc_res_t* dsdc_res;
        redis_res_t val_res;
        strbuf insert_buf;
        bool ok(true);
    }

    dsdc_res = (dsdc_res_t*) out;
    *dsdc_res = DSDC_INSERTED;

    // MM: If we have a checksum, we need to fetch the object and compare
    // We might be able to do better with a Lua script at some point
    if (cksum) {
        twait {
            m_redis.runCmd({ std::make_pair("HGET", 4), 
                             std::make_pair(key.base(), key.size()), 
                             std::make_pair("value", 5) }, 
                           mkevent(val_res));
        }

        if (val_res.is_err()) {
            *dsdc_res = DSDC_RPC_ERROR;
            ev->trigger(false);
            return;
        }

        if (val_res.obj().isnull()) {
            *dsdc_res = DSDC_DATA_DISAPPEARED; 
        } else if (!check_checksum(val_res.obj().to_str().cstr(),
                                   val_res.obj().to_str().len(),
                                   cksum)) {
            *dsdc_res = DSDC_DATA_CHANGED;
        }
    }

    if (*dsdc_res == DSDC_INSERTED) { 
        insert_buf << sfs_get_timenow();
        twait {
            m_redis.runCmd({ std::make_pair("HMSET", 5), 
                             std::make_pair(key.base(), key.size()),
                             std::make_pair("value", 5), 
                             std::make_pair(obj.base(), obj.size()),
                             std::make_pair("insert", 6), 
                             std::make_pair(str(insert_buf).cstr(), 
                                            insert_buf.len()) }, 
                             mkevent(val_res));
        }

        if (val_res.is_err()) {
            ok = false;
            *dsdc_res = DSDC_RPC_ERROR; 
        }     
    }

    ev->trigger(ok);

}

//-----------------------------------------------------------------------------

tamed void
redis_connection_t::handle_remove3(const void* in, void* out, evb_t ev) {

    tvars {
        const dsdc_remove3_arg_t* arg;
        dsdc_res_t* dsdc_res;
        redis_res_t val_res;
        bool ok(true);
        size_t removed;
    }

    arg = (const dsdc_remove3_arg_t*) in;
    dsdc_res = (dsdc_res_t*) out;

    *dsdc_res = DSDC_OK;
    twait {
        m_redis.runCmd({ std::make_pair("DEL", 3),
                         std::make_pair(arg->key.base(), arg->key.size()) }, 
                       mkevent(val_res));
    }

    if (val_res.is_err()) {
        *dsdc_res = DSDC_RPC_ERROR;
        ok = false;
    } else {
        removed = val_res.obj().to_int();
        if (!removed) {
            *dsdc_res = DSDC_NOTFOUND;
        }
    }

    ev->trigger(ok);

}

//-----------------------------------------------------------------------------

tamed void
redis_connection_t::timedcall(time_t sec, long nsec, u_int32_t procno, 
                              const void *in, void *out, aclnt_cb cb) {
    m_redis.setTimeout(sec);
    call(procno, in, out, cb);
}
