// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "async.h"
#include "arpc.h"
#include "tame.h"
#include "dsdc_prot.h"
#include <sys/statvfs.h>
#include "dsdc_const.h"

//=======================================================================

struct aiod_t {
public:
    aiod_t () {}
    int configure (int argc, char **argv);
    void init (evi_t ev, CLOSURE);
    void run (evi_t ev, CLOSURE);
    void dispatch (svccb *sbp);
private:
    void handle_str_to_file (svccb *sbp);
    void handle_file_to_str (svccb *sbp);
    void handle_remove (svccb *sbp);
    void handle_mkdir (svccb *sbp);
    void handle_statvfs (svccb *sbp);
    void handle_stat (svccb *sbp);

    evv_t::ptr m_eof_ev;
    ptr<axprt_unix> m_x;
    ptr<asrv> m_srv;
};

//-----------------------------------------------------------------------

void 
aiod_t::handle_str_to_file (svccb *sbp)
{
    RPC::aiod_prog_2::aiod2_str_to_file_srv_t<svccb> srv (sbp);
    const aiod_str_to_file_arg_t *arg = srv.getarg ();
    int rc = 0;
    const char *fnc = arg->file.cstr ();

    int fd = open (fnc, arg->flags, arg->mode);
    if (fd >= 0) {
        size_t bsz = 8196;
        const char *bp = arg->data.base ();
        const char *endp = arg->data.size () + bp;

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

        if (arg->sync) { fsync (fd); }
        close (fd);

    } else {
        if (!arg->canfail) {
            warn ("aiod2: open on file '%s' failed: %m\n", fnc);
        }
        rc = errno;
    }
    srv.reply (rc);
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
    srv.reply (rc);
}

//-----------------------------------------------------------------------

void 
aiod_t::handle_mkdir (svccb *sbp)
{
    RPC::aiod_prog_2::aiod2_mkdir_srv_t<svccb> srv (sbp);
    const aiod_mkdir_arg_t *arg = srv.getarg ();
    int rc = mkdir (arg->file.cstr (), arg->mode);
    srv.reply (rc);
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
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------
//-----------------------------------------------------------------------

void
aiod_t::dispatch (svccb *sbp)
{
    if (!sbp) {
        if (m_eof_ev) { m_eof_ev->trigger (); }
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
    default:                sbp->reject (PROC_UNAVAIL); break;
    }

}

//-----------------------------------------------------------------------

tamed void
aiod_t::init (evi_t ev)
{
    m_x = axprt_unix::alloc (0, dsdc_packet_sz);
    m_srv = asrv::alloc (m_x, aiod_prog_2, wrap (this, &aiod_t::dispatch));
    ev->trigger (0);
}

//-----------------------------------------------------------------------

tamed void
aiod_t::run (evi_t ev)
{
    twait { m_eof_ev = mkevent (); }
    ev->trigger (0);
}

//-----------------------------------------------------------------------

int
aiod_t::configure (int argc, char **argv)
{
    int ch;
    int rc = 0;
    while ((ch = getopt (argc, argv, "r:")) != -1) {
        switch (ch) {
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
    main_T(argc, argv);
    amain();
}
