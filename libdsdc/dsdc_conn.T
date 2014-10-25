// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "arpc.h"
#include "tame.h"
#include "dsdc_conn.h"
#include "pub3obj.h"
#include "dsdc.h"
#include "dsdc_util.h"

//-----------------------------------------------------------------------------

static str get_sha1(const char* script) {
    char buf[sha1::hashsize];
    sha1_hash (buf, script, strlen(script));
    strbuf b;
    b << hexdump (buf, sha1::hashsize);
    return b;
}

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

redis_connection_t::redis_connection_t() {
    m_redis.setReconnect(false);
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

const char* redis_connection_t::m_lua_get = " \n \
    local val = redis.call(\"hmget\", KEYS[1], \"value\", \"insert\")   \n \
    if val[1] == false then \n \
        return { 1 } \n \
    else \n \
        local insert_time = tonumber(val[2]) \n \
        local expire_time = tonumber(ARGV[1]) \n \
        if insert_time > 0 and expire_time >= insert_time then \n \
            return { 2 } \n \
        else \n \
            return { 0, val[1] } \n \
        end \n \
    end  ";

str redis_connection_t::m_lua_get_sha1 = 
    get_sha1(redis_connection_t::m_lua_get);

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
        int lua_code;
        pub3::obj_t luares;
        strbuf insert_buf;
        str insert_str, res_str;
    }

    arg  = (const dsdc_get3_arg_t*) in;
    dsdc_res = (dsdc_get_res_t*) out;
    time_to_expire = arg->time_to_expire;

    insert_time = (time_to_expire) ? (sfs_get_timenow() - time_to_expire) : 0;
    insert_buf << insert_time;
    insert_str = str(insert_buf);

    twait {
        m_redis.evalLua(m_lua_get, m_lua_get_sha1, 
                        { std::make_pair(arg->key.base(), arg->key.size()) },
                        { std::make_pair(insert_str.cstr(), insert_str.len()) },
                        mkevent(val_res));
    }
    
    (*dsdc_res).set_status(DSDC_OK);
    if (!val_res.is_err()) {
        
        luares = val_res.obj();
        lua_code = luares[0].to_int();

        switch (lua_code) {
        case 0:
            res_str = luares[1].to_str();
            *((*dsdc_res).obj) = res_str;
            break;
        case 1:
            (*dsdc_res).set_status(DSDC_NOTFOUND);
            break;
        case 2:
            (*dsdc_res).set_status(DSDC_EXPIRED);
            break;
        default:
            warn << "dsdc_panic: handle_get(): unknown code: " << lua_code
                 << "\n";
        };
        
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

const char* redis_connection_t::m_lua_put = " \n \
    local cksum = ARGV[3] \n \
    if cksum ~= nil then \n \
        local priorval = redis.call(\"hget\", KEYS[1], \"value\") \n \
        if priorval == false then \n \
            return 1 \n \
        end \n \
        local shaval = redis.sha1hex(priorval) \n \
        if shaval ~= cksum then \n \
            return 2 \n \
        end \n \
    end \n \
    redis.call(\"hmset\", KEYS[1], \"value\", ARGV[1], \"insert\", ARGV[2]) \n\
    return 0";

str redis_connection_t::m_lua_put_sha1 = 
    get_sha1(redis_connection_t::m_lua_put);

//-----------------------------------------------------------------------------

static str print_key(const dsdc_key_t& k) {
    char buffer[256];
    strbuf skey;

    for (size_t i = 0; i < k.size(); i++) {
        unsigned char c = k[i];
        if (c >= 32 && c < 127)
            sprintf(buffer, "%c", c);
        else
            sprintf(buffer, "\\x%02x", c);
        skey << buffer;
    }

    return skey;
}

//-----------------------------------------------------------------------------

tamed void
redis_connection_t::handle_put(void* out, const dsdc_key_t& key,
                               const dsdc_obj_t& obj,
                               dsdc_cksum_t* cksum, evb_t ev) {

    tvars {
        dsdc_res_t* dsdc_res;
        redis_res_t val_res;
        strbuf insert_buf, hash_buf;
        bool ok(true);
        vec<std::pair<const char*,size_t>> keys;
        vec<std::pair<const char*,size_t>> args;
        int lua_code;
        str insert_str, hash_str;
    }

    dsdc_res = (dsdc_res_t*) out;
    insert_buf << sfs_get_timenow();
    insert_str = str(insert_buf);

    keys.push_back(std::make_pair(key.base(), key.size()));
    args.push_back(std::make_pair(obj.base(), obj.size()));
    args.push_back(std::make_pair(insert_str.cstr(), insert_str.len()));
    if (cksum && !is_empty_checksum(*cksum)) {
        hash_buf << hexdump(cksum->base(), cksum->size());
        hash_str = str(hash_buf);
        args.push_back(std::make_pair(hash_str.cstr(), hash_str.len()));
    }

    twait {
        m_redis.evalLua(m_lua_put, m_lua_put_sha1, keys, args, 
                        mkevent(val_res));
    }

    if (val_res.is_err()) {
        ok = false;
        *dsdc_res = DSDC_RPC_ERROR;
    } else {
        lua_code = val_res.obj().to_int();
        switch (lua_code) {
        case 0:
            *dsdc_res = DSDC_INSERTED;
            break;
        case 1:
            *dsdc_res = DSDC_DATA_DISAPPEARED;
            break;
        case 2:
            *dsdc_res = DSDC_DATA_CHANGED;
            break;
        default:
            warn << "dsdc_panic: handle_put(): unknown code: " << lua_code
                 << "\n";
        };
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
