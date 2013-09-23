// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "async.h"
#include "arpc.h"
#include "tame.h"
#include "dsdc_prot.h"
#include <sys/statvfs.h>
#include "dsdc_const.h"
#include "parseopt.h"
#include "fscache.h"
#include "tame_io.h"

//=======================================================================

class aiod_t;

struct client_t {
public:
    client_t (ptr<axprt> x, aiod_t *a);
    void dispatch (svccb *sbp);
    ptr<asrv> m_srv;
    aiod_t *m_aiod;
};

//-----------------------------------------------------------------------

struct aiod_t {
public:
    aiod_t () : m_packet_size (dsdc_packet_sz), m_port (-1), m_listen_fd (-1) {}
    int configure (int argc, char **argv);
    void init (evi_t ev, CLOSURE);
    void run (evi_t ev, CLOSURE);
    void dispatch (svccb *sbp, client_t *cli);
private:
    void handle_str_to_file (svccb *sbp);
    void handle_file_to_str (svccb *sbp);
    void handle_remove (svccb *sbp);
    void handle_mkdir (svccb *sbp);
    void handle_statvfs (svccb *sbp);
    void handle_stat (svccb *sbp);
    void handle_glob (svccb *sbp);
    void inet_server (evi_t ev, CLOSURE);
    void listen_loop (evi_t ev, CLOSURE);

    evv_t::ptr m_eof_ev;
    size_t m_packet_size;
    int m_port;
    int m_listen_fd;
};

//-----------------------------------------------------------------------

client_t::client_t (ptr<axprt> x, aiod_t *a)
    : m_srv (asrv::alloc (x, aiod_prog_2, wrap (this, &client_t::dispatch))),
      m_aiod (a) {}

//-----------------------------------------------------------------------

void
client_t::dispatch (svccb *sbp)
{
    m_aiod->dispatch (sbp, this);
}

//-----------------------------------------------------------------------

static int
write_to_file (int fd, const char *fnc, const rpc_bytes<RPC_INFINITY> &buf)
{
    int rc = 0;
    size_t bsz = 8196;
    const char *bp = buf.base ();
    const char *endp = buf.size () + bp;
    
    while (bp < endp && rc >= 0) {
        size_t len = min<size_t> (bsz, endp - bp);
        rc = write (fd, bp, len);
        if (rc < 0) {
            warn ("aiod2: write failed on file %s: %m\n", fnc);
        } else if (rc == 0) {
            warn ("aiod2: unexpected 0-length write on file %s\n", fnc);
            rc = EINVAL;
        } else {
            bp += rc;
            rc = 0;
        }
    }
    return rc;
}

//-----------------------------------------------------------------------

void 
aiod_t::handle_str_to_file (svccb *sbp)
{
    RPC::aiod_prog_2::aiod2_str_to_file_srv_t<svccb> srv (sbp);
    const aiod_str_to_file_arg_t *arg = srv.getarg ();
    int rc = 0;
    str fn = arg->file;
    str fn_orig = fn;
    int flags = arg->flags; // XX throw these on the floor!


    if (arg->atomic) {
        flags = O_WRONLY | O_CREAT | O_EXCL;
        strbuf b ("%s~%d", fn.cstr (), rand ());
        fn = b;
    } else {
        // ask for truncation in all cases; makes no sense otherwise
        flags = O_WRONLY | O_CREAT | O_TRUNC;
    }
    const char *fnc = fn.cstr();


    int fd = open (fnc, flags, arg->mode);
    if (fd < 0) {
        if (!arg->canfail) {
            warn ("aiod2: open on file '%s' failed: %m\n", fnc);
        }
        rc = errno;
    } else { 
        rc = write_to_file (fd, fnc, arg->data);
        if (rc == 0) {
            if (arg->sync && fsync (fd) != 0) { 
                warn ("fsync on %s failed: %m\n", fnc); 
            }
        }
        close (fd);
    }

    if (arg->atomic && rc == 0) {
        rc = rename (fn.cstr (), fn_orig.cstr ());
        if (rc) {
            warn ("aiod2: rename(%s,%s) failed\n", fn.cstr (), fn_orig.cstr ());
            rc = errno;
        }
    }
    srv.reply (rc);
}

//-----------------------------------------------------------------------

void
aiod_t::handle_glob (svccb *sbp)
{
    RPC::aiod_prog_2::aiod2_glob_srv_t<svccb> srv (sbp);
    const aiod_glob_arg_t *arg = srv.getarg ();
    aiod_glob_res_t res;
    vec<str> tmp;

    int rc = fscache::simple_backend_t::s_glob (arg->dir, arg->pattern, &tmp);
    res.set_code (rc);
    if (rc == 0) {
        for (size_t i= 0; i < tmp.size (); i++) {
            res.files->push_back (tmp[i]);
        }
    }
    srv.reply (res);
}

//-----------------------------------------------------------------------

void 
aiod_t::handle_file_to_str (svccb *sbp)
{
    RPC::aiod_prog_2::aiod2_file_to_str_srv_t<svccb> srv (sbp);
    const aiod_file_t *arg = srv.getarg ();
    aiod_file_to_str_res_t res;
    str s = file2str (*arg);
    if (s) {
        res.set_code (0);
        res.data->setsize (s.len ());
        memcpy (res.data->base (), s.cstr (), s.len ());
    } else {
        res.set_code (errno);
    }
    srv.reply (res);
}

//-----------------------------------------------------------------------

void 
aiod_t::handle_remove (svccb *sbp)
{
    RPC::aiod_prog_2::aiod2_remove_srv_t<svccb> srv (sbp);
    const aiod_file_t *arg = srv.getarg ();
    int rc = unlink (arg->cstr ());
    srv.reply (rc == 0 ? rc : errno);
}

//-----------------------------------------------------------------------

void 
aiod_t::handle_mkdir (svccb *sbp)
{
    RPC::aiod_prog_2::aiod2_mkdir_srv_t<svccb> srv (sbp);
    const aiod_mkdir_arg_t *arg = srv.getarg ();
    int rc = mkdir (arg->file.cstr (), arg->mode);
    srv.reply (rc == 0 ? rc : errno);
}

//-----------------------------------------------------------------------

void 
aiod_t::handle_statvfs (svccb *sbp)
{
    RPC::aiod_prog_2::aiod2_statvfs_srv_t<svccb> srv (sbp);
    const aiod_file_t *arg = srv.getarg ();
    aiod_statvfs_res_t res;
    struct statvfs sv;

    int rc = statvfs (arg->cstr (), &sv);
    if (rc == 0) {
        aiod_statvfs_t s;
#define A(field) \
        s.aiod_f_##field = sv.f_##field;
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
        res.set_code (0);
        *res.stat = s;
    } else {
        res.set_code (errno);
    }
    srv.reply (res);
}

//-----------------------------------------------------------------------

void
aiod_t::handle_stat (svccb *sbp)
{
    RPC::aiod_prog_2::aiod2_stat_srv_t<svccb> srv (sbp);
    const aiod_file_t *arg = srv.getarg ();
    aiod_stat_res_t res;
    struct stat sb;
    
    int rc = stat (arg->cstr (), &sb);
    if (rc == 0) {
        aiod_stat_t s;

#define A(field) \
        s.aiod_st_##field = sb.st_##field;

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
        res.set_code (0);
        *res.stat = s;

    } else {
        res.set_code (errno);
    }
    srv.reply (res);
}

//-----------------------------------------------------------------------

void
aiod_t::dispatch (svccb *sbp, client_t *cli)
{
    if (!sbp) {
        if (m_eof_ev) { m_eof_ev->trigger (); }
        delete cli;
        return;
    }

    switch (sbp->proc ()) {
    case AIOD2_NULL:        sbp->replyref (NULL);       break; 
    case AIOD2_STR_TO_FILE: handle_str_to_file (sbp);   break; 
    case AIOD2_FILE_TO_STR: handle_file_to_str (sbp);   break;
    case AIOD2_REMOVE:      handle_remove (sbp);        break;
    case AIOD2_MKDIR:       handle_mkdir (sbp);         break;
    case AIOD2_STATVFS:     handle_statvfs (sbp);       break;
    case AIOD2_STAT:        handle_stat (sbp);          break;
    case AIOD2_GLOB:        handle_glob (sbp);          break;
    default:                sbp->reject (PROC_UNAVAIL); break;
    }

}

//-----------------------------------------------------------------------

tamed void
aiod_t::inet_server (evi_t ev)
{
    tvars {
        int rc (0);
    }
    if ((m_listen_fd = inetsocket (SOCK_STREAM, m_port)) < 0) {
        warn ("failed to bind to port %d: %m\n", m_port);
        rc = -1;
    } else {
        listen (m_listen_fd, 100);
    }
    ev->trigger (rc);
}

//-----------------------------------------------------------------------

tamed void
aiod_t::init (evi_t ev)
{
    tvars {
        int rc (0);
        ptr<axprt_unix> x;
    }
    if (m_port > 0) {
        twait { inet_server (mkevent (rc)); }
    } else {
        x = axprt_unix::alloc (0, m_packet_size);
        if (x->ateof ()) {
            warn ("bailing out on socket error\n");
            rc = -1;
        } else {
            vNew client_t (x, this);
        }
    } 
    ev->trigger (0);
}

//-----------------------------------------------------------------------

tamed void
aiod_t::listen_loop (evi_t ev)
{
    tvars {
        int fd;
        ptr<axprt_stream> x;
        sockaddr_in sin;
        socklen_t sinlen (sizeof (sin));
    }
    while (true) {
        twait { tame::waitread (m_listen_fd, mkevent ()); }
        bzero (&sin, sizeof (sin));
        fd = accept (m_listen_fd, reinterpret_cast<sockaddr *> (&sin),
                     &sinlen);
        if (fd < 0) {
            warn ("accept error: %m\n");
        } else {
            x = axprt_stream::alloc (fd, m_packet_size);
            vNew client_t (x, this);
        }
    }
    ev->trigger (0);
}

//-----------------------------------------------------------------------

tamed void
aiod_t::run (evi_t ev)
{
    tvars {
        int rc (0);
    }
    if (m_listen_fd >= 0) {
        twait { listen_loop (mkevent (rc)); }
    } else {
        twait { m_eof_ev = mkevent (); }
    }
    ev->trigger (rc);
}

//-----------------------------------------------------------------------

int
aiod_t::configure (int argc, char **argv)
{
    int ch;
    int rc = 0;
    size_t sz;
    while ((ch = getopt (argc, argv, "s:p:P")) != -1) {
        switch (ch) {
        case 'P':
            m_port = dsdc_aiod2_remote_port;
            break;
        case 's':
            if (!convertint (optarg, &sz)) {
                warn ("cannot convert '%s' to a packet size\n", optarg);
                rc = -1;
            } else {
                m_packet_size = sz;
            }
            break;
        case 'p':
            if (!convertint (optarg, &m_port)) {
                warn ("cannot convert '%s' to a port\n", optarg);
            }
            break;
        default:
            warn ("Unrecognized option: %c\n", ch);
            rc = -1;
            break;
        }
    }
    return rc;
}

//-----------------------------------------------------------------------

tamed static void
main_T (int argc, char **argv)
{
    tvars {
        aiod_t aiod;
        int rc;
    }

    if ((rc = aiod.configure (argc, argv)) != 0)  { /* bad config */ }
    else { 
        twait { aiod.init (mkevent (rc)); }
        if (rc == 0) {
            twait { aiod.run (mkevent (rc)); }
        }
    }
    exit (rc);
}

//-----------------------------------------------------------------------

int 
main (int argc, char *argv[])
{
    setprogname (argv[0]);
    srand (getpid () ^ time (NULL));
    main_T(argc, argv);
    amain();
}

//-----------------------------------------------------------------------

