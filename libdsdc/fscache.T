// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "fscache.h"
#include "dsdc_prot.h"
#include "crypt.h"
#include "arpc.h"
#include "sha1.h"
#include "dynenum.h"
#include "parseopt.h"
#include <dirent.h>
#include "rxx.h"

#ifndef __STDC_FORMAT_MACROS
# define __STDC_FORMAT_MACROS
#endif
#include <inttypes.h>

namespace fscache {
    
    //-----------------------------------------------------------------------

    cfg_t::cfg_t (bool fake_jail)
            : _backend (BACKEND_AIOD2),
              _n_levels (3),
              _n_dig (1),
              _root ("/disk/fscache"),
              _n_aiods (5),
              _shmsize (0x200000),
              _maxbuf (0x10000),
              _blocksz (0x4000),
              _file_mode (0664),
              _fake_jail (fake_jail),
              _skip_sha (false),
              _debug (0),
              _rollover_time (120),
              _write_delay (60),
              _wdp (5),
              _max_packet_size (dsdc_packet_sz),
              _write_atomic (true),
              _cache_on_load (false),
              _do_fsync (false) {}

    //-----------------------------------------------------------------------
    
    void
    cfg_t::set_debug_options (const char *s)
    {
        _debug = 0;
        for (const char *cp = s; *cp; cp++) {
            switch (*cp) {
            case 't': _debug |= DEBUG_OP_TRACE; break;
            default:
                warn ("unknown config flag '%c' passed\n", *cp);
                break;
            }
        }
    }

    //-----------------------------------------------------------------------

    str
    cfg_t::get_debug_docs ()
    {
        strbuf b;
        b << "  -t   debug operation traces\n";
        return b;
    }

    //-----------------------------------------------------------------------

    str cfg_t::get_debug_optstr () { return "s"; }

    //-----------------------------------------------------------------------

    str
    cfg_t::root () const
    {
        str ret;
        if (_fake_jail && _jaildir) {
            strbuf b ("%s/%s", _jaildir.cstr (), _root.cstr ());
            ret = b;
        } else {
            ret = _root;
        }
        return ret;
    }

    //-----------------------------------------------------------------------

    str
    file_id_t::fullpath (int lev, int ndig) const
    {

#define SZ 32
#define NDIG 8
#define FMT_SZ 10

        char buf[SZ];
        char tmp[NDIG+1];
        char fmt[FMT_SZ];
        snprintf (fmt, FMT_SZ, "%%0%dx", NDIG);
        int rc = snprintf (buf, SZ, fmt, _index);
        assert (lev < rc);

        if (ndig <= 0) ndig = 1;
        ndig = min<int> (NDIG, ndig);
        lev = min<int> (lev, SZ/ndig);

        const char *cp = buf;
        strbuf out;

        memset (tmp, 0, NDIG+1);

        for (int i = 0; i < lev; i++) {
            memcpy (tmp, cp, ndig);
            cp += ndig;
            out << tmp << "/";
        }
        out << _name;
        return out;
    }
#undef SZ
#undef NDIG
#undef FMT_SZ

    //-----------------------------------------------------------------------

    engine_t::engine_t (const cfg_t *c) : 
        _cfg (c),
        _alive (New refcounted<bool> (true))
    {
        switch (c->backend ()) {
        case BACKEND_SIMPLE:
            _backend = New refcounted<simple_backend_t> ();
            break;
        case BACKEND_AIOD:
            _backend = New refcounted<aiod_backend_t> (c);
            break;
        case BACKEND_AIOD2:
            _backend = New refcounted<aiod2_backend_t> (c);
            break;
        case BACKEND_SIMPLE_FAST:
            _backend = New refcounted<simple_fast_backend_t> ();
            break;
        case BACKEND_THREADS:
            _backend = New refcounted<thread_backend_t> (c);
            break;
        case BACKEND_HYBRID:
            _backend_v.setsize (2);
            _backend_v[0] = New refcounted<simple_fast_backend_t> ();
            _backend_v[1] = New refcounted<aiod_backend_t> (c);
            _backend = _backend_v[0];
            break;
        default:
            panic ("Unknown backend given: %d\n", int (c->backend ()));
            break;
        }
    }

    //-----------------------------------------------------------------------

    bool
    engine_t::init ()
    {
        bool ret;
        ret = _backend && _backend->init ();
        if (ret && _cfg->backend () == BACKEND_HYBRID) {
            rotate ();
        }
        return ret;
    }

    //-----------------------------------------------------------------------

    tamed void
    engine_t::rotate ()
    {
        tvars {
            ptr<bool> alive;
            time_t t;
        }
        t = _cfg->rollover_time ();
        alive = _alive;
        twait {
            delaycb (t, 0, mkevent ());
        }

        if (*alive) {
            warn << "delayed " << t << "s; switching over to aiod backend\n";
            _backend = _backend_v[1];
        }
    }

    //-----------------------------------------------------------------------

    engine_t::~engine_t ()
    {
        *_alive = false;
    }
    
    //-----------------------------------------------------------------------

    tamed void
    engine_t::load_T (file_id_t id, cbits_t cb)
    {
        tvars {
            str fn;
            str out;
            time_t tm (0);
            str ret_str;
            int rc;
            bool ss;
        }
        ss = skip_sha ();
        fn = filename (id);
        twait { _backend->file2str (fn, mkevent (rc, out)); }
        if (rc == 0) {
            fscache_file_t file;
            char digest[sha1::hashsize];
            if (!str2xdr (file, out)) {
                warn ("Cannot decode file: %s\n", fn.cstr ());
                rc = -EINVAL;
            } else if (!ss && !sha1_hashxdr (digest, file.data)) {
                warn ("Cannot hash data from file: %s\n", fn.cstr ());
                rc = -EINVAL;
            } else if (!ss &&
                       memcmp (file.checksum.base (), digest,
                               sha1::hashsize) != 0) {
                warn ("Bad checksum on file: %s\n", fn.cstr ());
                rc = -EINVAL;
            } else {
                tm = file.data.timestamp;
                mstr m (file.data.data.size ());
                memcpy (m.cstr(), file.data.data.base (),
                        file.data.data.size ());
                ret_str = m;
            }
        }

        (*cb) (rc, tm, ret_str);
    }

    //-----------------------------------------------------------------------

    static bool
    write_null_checksum (char *v)
    {
        memset (v, 0, sha1::hashsize);
        return true;
    }

    //-----------------------------------------------------------------------

    tamed void
    engine_t::glob (file_id_t pattern, vec<str> *out, evi_t ev)
    {
        tvars {
            str dummy;
            int rc;
        }
        dummy = filename (pattern);
        static rxx x ("^(.*?)/([^/]+)$");
        if (!x.match (dummy)) {
            warn << "Cannot split glob pattern '" << dummy << "'\n";
            rc = -EINVAL;
        } else {
            twait { _backend->glob (x[1], x[2], out, mkevent (rc)); }
        }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    engine_t::store_T (file_id_t id, time_t tm, str data, evi_t ev)
    {
        tvars {
            str fn;
            int rc;
            fscache_file_t file;
            str out;
            bool ss;
        }
        ss = skip_sha ();
        fn = filename (id);
        file.data.timestamp = tm;
        file.data.data = data;
        if (ss && !write_null_checksum (file.checksum.base ())) {
            warn ("Cannot write empty checksum for file: %s\n", fn.cstr ());
            rc = -EINVAL;
        } else if (!ss && !sha1_hashxdr (file.checksum.base (), file.data)) {
            warn ("Cannot compute checksum for file: %s\n", fn.cstr ());
            rc = -EINVAL;
        } else if (!(out = xdr2str (file))) {
            warn ("Cannot convert file to XDR form: %s\n", fn.cstr ());
            rc = -EINVAL;
        } else {
            twait {
                _backend->str2file (fn, out, _cfg->file_mode (), mkevent (rc));
            }
        }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    engine_t::remove_T (file_id_t id, evi_t ev)
    {
        tvars {
            str fn;
            int rc;
        }
        fn = filename (id);
        twait { _backend->remove (fn, mkevent (rc)); }
        ev->trigger (rc);
    }
    
    //-----------------------------------------------------------------------

    str
    engine_t::filename (file_id_t id) const
    {
        strbuf b;
        str s;
        b << _cfg->root ();
        b << "/" ;
        s = id.fullpath (_cfg->n_levels (), _cfg->n_dig ());
        b << s;
        return b;
    }

    //-----------------------------------------------------------------------
    
    void
    simple_backend_t::glob (str d, str p, vec<str> *out, evi_t ev)
    {
        int rc = s_glob (d, p, out);
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    int
    simple_backend_t::s_glob (str d, str p, vec<str> *out)
    {
        int ret = 0;
        DIR *dir = opendir (d.cstr ());
        rrxx x;
        if (!dir) {
            ret = 0 - errno;
        } else if (!x.compile (p)) {
            warn << "could not compile pattern '" << p << "'\n";
            ret = - EINVAL;
        } else {
            struct dirent *de;
            while ((de = readdir (dir))) {
                str n = de->d_name;
                if (x.search (n)) { out->push_back (n); }
            }
        }
        if (dir) closedir (dir);
        return ret;
    }

    //-----------------------------------------------------------------------

    int
    simple_backend_t::s_file2str (str fn, str *out)
    {
        int ret;
        str s = ::file2str (fn);
        if (s) {
            ret = 0;
        } else {
            ret = 0 - errno;
        }
        *out = s;
        return ret;
    }


    //-----------------------------------------------------------------------

    void
    simple_backend_t::file2str (str fn, evis_t ev)
    {
        int ret;
        str out;
        ret = s_file2str (fn, &out);
        ev->trigger (ret, out);
    }

    //-----------------------------------------------------------------------

    int
    simple_fast_backend_t::s_str2file (str fn, str s, int mode, bool canfail)
    {
        int fd = ::open (fn.cstr (), O_WRONLY | O_CREAT, mode);
        int rc = 0;
        const char *fnc = fn.cstr ();

        if (fd >= 0) {
            size_t bsz = 8196;
            const char *bp = s.cstr ();
            const char *endp = s.cstr () + s.len ();

            while (bp < endp && rc >=0 ) {
                size_t len = min<size_t> (bsz, endp - bp);
                rc = write (fd, bp, len);
                if (rc < 0) {
                    warn ("write failed on file %s: %m\n", fnc);
                } else if (rc == 0) {
                    warn ("unexpected 0-length write on file %s\n", fnc);
                    rc = EINVAL;
                } else {
                    bp += rc;
                    rc = 0;
                }
            }
            close (fd);
        } else {
            rc = errno;
            if (!canfail) {
                warn ("open on file '%s' failed: %m\n", fnc);
            }
        }
        return (0 - rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    backend_t::str2file_T (str fn, str s, int mode, evi_t ev)
    {
        tvars {
            int rc;
        }
        twait { str2file_inner (fn, s, mode, true, mkevent (rc)); }
        if (rc == -ENOENT) {
            twait { mk_parent_dirs (fn, 0777, mkevent (rc)); }
            if (rc == 0) {
                twait { str2file_inner (fn, s, mode, false, mkevent (rc)); }
            }
        }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------
    
    void
    simple_fast_backend_t::str2file_inner (str fn, str s, int mode, 
                                           bool cf, evi_t ev)
    {
        int rc = simple_fast_backend_t::s_str2file (fn, s, mode, cf);
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    int
    simple_backend_t::s_str2file (str fn, str s, int mode, bool canfail)
    {
        bool b = ::str2file (fn, s, mode);
        int rc = (b && errno > 0) ? -errno : -EIO;
        return rc;
    }

    //-----------------------------------------------------------------------

    void
    simple_backend_t::str2file_inner (str fn, str s, int md, bool cf, evi_t ev)
    {
        int rc = s_str2file (fn, s, md, cf);
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    int
    simple_backend_t::s_remove (str f)
    {
        int rc = unlink (f.cstr ());
        if (rc != 0) { rc = 0 - errno; }
        return rc;
    }

    //-----------------------------------------------------------------------

    void
    simple_backend_t::remove (str f, evi_t ev)
    {
        int rc = s_remove (f);
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    aiod_backend_t::file2str_T (str fn, evis_t ev)
    {
        tvars {
            int rc, crc;
            ptr<aiofh> fh;
            ptr<aiobuf> buf, b2;
            off_t pos, sz;
            strbuf b;
            struct stat *sb;
            str ret;
            ssize_t rsz;
            bool eof;
            ssize_t blocksz;
        }
        blocksz = _cfg->blocksz ();

        twait { _aiod->open (fn, O_RDONLY, 0, mkevent (fh, rc)); }

        if (rc == 0) {
            twait { fh->fstat (mkevent (sb, rc)); }
            if (rc != 0) {
                warn << "fstat failed on file: " << fn << "\n";
            } else {
                sz = sb->st_size;
                if (!(buf = _aiod->bufalloc (blocksz))) {
                    rc = -ENOMEM;
                } else {
                    eof = false;
                    for (pos = 0; pos < sz && rc == 0 && !eof; pos += rsz) {
                        twait { fh->read (pos, buf, mkevent (b2, rsz, rc)); }
                        if (rc != 0) {
                            errno = rc;
                            warn ("Read error on file (%s): %m\n", fn.cstr ());
                        } else if (rsz < 0) {
                            warn ("Got unexpected failed read on file: %s\n",
                                  fn.cstr ());
                        } else {
                            if (rsz < blocksz) {
                                eof = true;
                            }
                            b.tosuio ()->copy (b2->base (), rsz);
                        }
                    }
                    if (rc == 0) {
                        if (b.tosuio ()->resid () != size_t (sz)) {
                            warn << "While reading " << fn << ": "
                            << "exepcted " << sz << " bytes; got "
                            << b.tosuio ()->resid () << " bytes instead\n";
                        }
                        ret = b;
                    }
                }
            }
            twait { fh->close (mkevent (crc)); }
            fh = NULL;
        }

        if (rc > 0)  {
            // DM's aiod system will return rcs > 0 with the correct
            // errno on the case of errors.  But for our purposes, we're
            // reversing the polarity of errnos.
            rc = 0 - rc;
        }
        ev->trigger (rc, ret);
    }

    //-----------------------------------------------------------------------

    tamed void
    aiod_backend_t::str2file_T (str fn, str s, int mode, evi_t ev)
    {
        tvars {
            ptr<aiofh> fh;
            ptr<aiobuf> buf,b2;
            int rc;
            const char *cp;
            off_t pos;
            const char *ep (s.cstr () + s.len ());
            ssize_t wsz, bsz;
            size_t blocksz;
            int flags (O_WRONLY|O_CREAT);
            int i;
        }
        blocksz = _cfg->blocksz ();


        for (i = 0; i < 2; i++) {
            twait {
                _aiod->open (fn, flags, mode, mkevent (fh, rc));
            }

            // Remember: DM's aio library returns errnos in the
            // positive space, so check against that here..
            if (i == 0 && !fh && rc == ENOENT) {
                twait { mk_parent_dirs (fn, 0777, mkevent (rc)); }
            }
        }

        if (rc == 0) {
            if (!(buf = _aiod->bufalloc (blocksz))) {
                rc = -ENOMEM;
            } else {
                for (pos = 0, cp = s.cstr (); cp < ep && rc == 0;
                     pos += blocksz, cp += blocksz) {
                    bsz = min<ssize_t> (blocksz, ep - cp);
                    memcpy (buf->base (), cp, bsz);
                    twait {
                        fh->swrite (pos, buf, 0, bsz, mkevent (b2, wsz, rc));
                    }
                    if (rc != 0) {
                        warn ("Bad write to file (%s): %d\n", fn.cstr (), rc);
                    } else if (wsz != bsz) {
                        warn ("Short write to file (%s): "
                              "expected %zd bytes, got %zd\n",
                              fn.cstr (), bsz, wsz);
                        rc = -EIO;
                    }
                }
            }
            twait { fh->close (mkevent (rc)); }
            if (rc != 0) {
                warn ("Close failed on file (%s): %d\n", fn.cstr (), rc);
            }
        }

        if (rc > 0) {
            // See comment above.
            rc = 0 - rc;
        }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    aiod_backend_t::remove_T (str f, evi_t ev)
    {
        tvars {
            int rc;
        }
        twait { _aiod->unlink (f, mkevent (rc)); }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    aiod_backend_t::aiod_backend_t (const cfg_t *c) : _cfg (c)
    {
        _aiod = New aiod (_cfg->n_aiods (), _cfg->shmsize (), _cfg->maxbuf ());
    }

    //-----------------------------------------------------------------------

    aiod_backend_t::~aiod_backend_t ()
    {
        if (_aiod) _aiod->finalize ();
    }

    //-----------------------------------------------------------------------

    tamed void
    backend_t::mk_parent_dirs (str s, int mode, evi_t ev)
    {
        tvars {
            mstr dir (s.len () + 1);
            char *ep;
            const char *bp;
            int rc (0);
            bool first;
        }

        memcpy (dir.cstr (), s.cstr (), s.len () + 1);
        bp = ep = dir.cstr ();

        for (first = true; *ep && rc == 0; ep++, first = false) {
            if (*ep == '/' && !first) {
                *ep = 0;
                twait { mkdir (bp, mode, mkevent (rc)); }
                if (rc == -EEXIST) {
                    rc = 0;
                } else if (rc != 0) {
                    errno = -rc;
                    warn ("could not make directory %s: %m\n", bp);
                }
                *ep = '/';
            }
        }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    aiod_backend_t::mkdir_T (str d, int mode, evi_t ev)
    {
        tvars {
            int rc;
        }
        twait { _aiod->mkdir (d, mode, mkevent (rc)); }
        ev->trigger (0 - rc);
    }

    //=======================================================================

    aiod2_backend_t::aiod2_backend_t (const cfg_t *c) 
        : _cfg (c)
    {
        size_t na = c->n_aiods ();
        size_t ps = c->max_packet_size ();
        _aiod = New refcounted<aiod2::mgr_t> (na, ps);
    }

    //-----------------------------------------------------------------------

    aiod2_backend_t::~aiod2_backend_t () { _aiod->kill (); }

    //-----------------------------------------------------------------------

    bool aiod2_backend_t::init () { return _aiod->init (); }

    //-----------------------------------------------------------------------

    tamed void
    aiod2_backend_t::file2str_T (str fn, evis_t ev) 
    {
        tvars {
            int rc;
            str s;
        }
        twait { _aiod->file2str (fn, mkevent (rc, s)); }
        ev->trigger (0 - rc, s);
    }

    //-----------------------------------------------------------------------

    tamed void
    aiod2_backend_t::str2file_inner_T (str f, str d, int mode, bool c, evi_t ev)
    {
        tvars {
            int rc;
            aiod2::write_opts_t wo (aiod2::WO_NONE);
            int wf;
        }
        if (_cfg->write_atomic ()) {
            wo = aiod2::write_opts_t (int (wo) | int (aiod2::WO_ATOMIC));
        }
        if (_cfg->do_fsync ()) {
            wo = aiod2::write_opts_t (int (wo) | int (aiod2::WO_SYNC)); 
        }
        if (c) { 
            wo = aiod2::write_opts_t (int (wo) | int (aiod2::WO_CANFAIL)); 
        }
        wf = O_CREAT | O_WRONLY | O_TRUNC;
        twait { _aiod->str2file (f, d, wf, mode, wo, mkevent (rc)); }
        ev->trigger (0 - rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    aiod2_backend_t::remove_T (str f, evi_t ev)
    {
        tvars {
            int rc;
        }
        twait { _aiod->remove (f, mkevent (rc)); }
        ev->trigger (0 - rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    aiod2_backend_t::mkdir_T (str f, int mode, evi_t ev)
    {
        tvars {
            int rc;
        }
        twait { _aiod->mkdir (f, mode, mkevent (rc)); }
        ev->trigger (0 - rc);
    }

    //-----------------------------------------------------------------------
    
    tamed void
    aiod2_backend_t::glob_T (str d, str f, vec<str> *out, evi_t ev)
    {
        tvars {
            int rc;
        }
        twait { _aiod->glob (d, f, out, mkevent (rc)); }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    aiod2_backend_t::statvfs_T (str d, struct statvfs *buf, evi_t ev)
    {
        tvars {
            int rc;
        }
        twait { _aiod->statvfs (d, buf, mkevent (rc)); }
        ev->trigger (0 - rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    aiod2_backend_t::stat_T (str d, struct stat *buf, evi_t ev)
    {
        tvars {
            int rc;
        }
        twait { _aiod->stat (d, buf, mkevent (rc)); }
        ev->trigger (0 - rc);
    }

    //=======================================================================

    
    int 
    simple_backend_t::s_mkdir (str d, int mode)
    {
        int rc = ::mkdir (d.cstr (), mode);
        if (rc != 0) rc = -errno;
        return rc;
    }

    //-----------------------------------------------------------------------

    void
    simple_backend_t::mkdir (str d, int mode, evi_t ev)
    {
        int rc = s_mkdir (d, mode);
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    engine_t::statvfs (struct statvfs *buf, evi_t ev)
    {
        tvars {
            str d;
            int rc;
        }

        if (!_cfg || !(d = _cfg->root ())) {
            d = ".";
        }

        twait { _backend->statvfs (d, buf, mkevent (rc)); }
        if (rc != 0) {
            warn ("statvfs failed on root directory '%s': %m\n", d.cstr ());
        }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    int
    simple_backend_t::s_statvfs (str d, struct statvfs *buf)
    {
        int rc = ::statvfs (d.cstr (), buf);
        if (rc != 0) rc = -errno;
        return rc;
    }

    //-----------------------------------------------------------------------

    int
    simple_backend_t::s_stat (str f, struct stat *sb)
    {
        int rc = ::stat (f.cstr (), sb);
        if (rc != 0) rc = -errno;
        return rc;
    }

    //-----------------------------------------------------------------------

    void
    simple_backend_t::stat (str f, struct stat *sb, evi_t ev)
    {
        ev->trigger (s_stat (f, sb));
    }

    //-----------------------------------------------------------------------

    void
    simple_backend_t::statvfs (str d, struct statvfs *buf, evi_t ev)
    {
        int rc = s_statvfs (d, buf);
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    tamed void
    aiod_backend_t::statvfs_T (str d, struct statvfs *buf, evi_t ev)
    {
        tvars {
            int rc;
            struct statvfs *tmp (NULL);
        }
        twait { _aiod->statvfs (d.cstr (), mkevent (tmp, rc)); }
        if (rc == 0 && tmp) {
            *buf = *tmp;
        } else if (rc != 0) {
            rc = -rc;
        }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    str
    file_id_t::to_str () const
    { return strbuf ("%s:%" PRIu32, _name.cstr (), _index); }

    //-----------------------------------------------------------------------

    class backend_tab_t : public dynamic_enum_t {
    public:
        backend_tab_t ()
            : dynamic_enum_t (int (BACKEND_AIOD2), true, "backends")
        {
            pair_t tab[] = { { "aiod", int (BACKEND_AIOD) },
                             { "simple", int (BACKEND_SIMPLE) },
                             { "simplefast", int (BACKEND_SIMPLE_FAST) },
                             { "thread", int (BACKEND_THREADS) },
                             { "hybrid", int (BACKEND_HYBRID) },
                             { "aiod2", int (BACKEND_AIOD2) },
                             { NULL, 0 }
            };
            init (tab, true);
        }
        backend_typ_t lookup (str s) const;
    };

    //-----------------------------------------------------------------------

    static backend_tab_t backend_tab;

    //-----------------------------------------------------------------------

    backend_typ_t
    backend_tab_t::lookup (str s) const
    {
        s = mytolower (s);
        int i;
        backend_typ_t ret = BACKEND_ERROR;
        if (dynamic_enum_t::lookup (s, &i)) { ret = backend_typ_t (i); }
        return ret;
    }

    //-----------------------------------------------------------------------

    backend_typ_t
    str2backend (const str &s)
    {
        return backend_tab.lookup (s);
    }

    //-----------------------------------------------------------------------

    str
    backend2str (backend_typ_t t)
    {
        str ret = "none";
        switch (t) {
        case BACKEND_AIOD: ret = "aiod"; break;
        case BACKEND_SIMPLE: ret = "simple"; break;
        case BACKEND_SIMPLE_FAST: ret = "simple-fast"; break;
        case BACKEND_THREADS: ret = "threads"; break;
        case BACKEND_HYBRID: ret = "hybrid"; break;
        case BACKEND_AIOD2: ret = "aiod2"; break;
        default: break;
        }
        return ret;
    }

    //============================= write_delay_engine_t ==================

    tamed void
    write_delay_engine_t::node_t::store (engine_t *e, evv_t ev)
    {
        tvars {
            int rc;
        }
        twait { 
            e->engine_t::store (m_fid, m_file_time, m_data, mkevent (rc)); 
        }

        if (rc) { 
            errno = rc;
            str fn = e->filename (m_fid);
            warn ("write_delay_engine_t: failed to write file %s: %m\n", 
                  fn.cstr ());
        }
        ev->trigger();
        delete this;
    }

    //-----------------------------------------------------------------------

    tamed void
    write_delay_engine_t::lock (file_id_t fid, 
                                write_delay_engine_t::lock_ev_t ev)
    {
        tvars {
            ptr<write_delay_engine_t::lock_handle_t> lh;
        }
        if (use_cache ()) {
            twait { 
                m_locks.acquire (&lh, fid.name (), tame::lock_t::EXCLUSIVE, 
                                 mkevent ()); 
            }
        }
        ev->trigger (lh);
    }

    //-----------------------------------------------------------------------

    tamed void
    write_delay_engine_t::store_T (file_id_t id, time_t tm, str data, evi_t ev)
    {
        tvars {
            write_delay_engine_t::node_t *n;
            ptr<write_delay_engine_t::lock_handle_t> lh;
            int rc (0);
        }
        assert (data);

        twait { lock (id, mkevent (lh)); }

        if ((n = m_tab[id.name ()])) {
            n->m_data = data;
            n->m_file_time = tm;
            n->mark_dirty ();
        } else if (use_cache ()) {
            insert (id, tm, data, true);
        } else {
            twait { engine_t::store (id, tm, data, mkevent (rc)); }
        }
        
        lh = NULL;
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    void
    write_delay_engine_t::insert (file_id_t fid, time_t t, str d, bool dirty)
    {
        assert (!m_tab[fid.name ()]);
        assert (d);
        node_t *n = New node_t (fid, t, d, dirty);
        m_tab.insert (n);
        m_queue.insert_tail (n);
    }

    //-----------------------------------------------------------------------

    tamed void
    write_delay_engine_t::load_T (file_id_t id, cbits_t cb)
    {
        tvars {
            write_delay_engine_t::node_t *n;
            int rc;
            time_t tm;
            str data;
            ptr<write_delay_engine_t::lock_handle_t> lh;
        }

        twait { lock (id, mkevent (lh)); }

        if ((n = m_tab[id.name ()])) {
            rc = 0;
            tm = n->m_file_time;
            data = n->m_data;
        } else {
            twait { engine_t::load (id, mkevent (rc, tm, data)); }
            if (rc == 0 && data && use_cache () && _cfg->cache_on_load ()) {
                insert (id, tm, data, false);
            }
        }

        lh = NULL;

        (*cb) (rc, tm, data);
    }

    //-----------------------------------------------------------------------

    tamed void
    write_delay_engine_t::remove_T (file_id_t id, evi_t ev)
    {
        tvars {
            write_delay_engine_t::node_t *n;
            int rc;
        }
        if ((n = m_tab[id.name ()])) {
            m_tab.remove (n);
            m_queue.remove (n);
            delete n;
        }
        twait { engine_t::remove (id, mkevent (rc)); }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    write_delay_engine_t::write_delay_engine_t (const cfg_t *c) 
        : engine_t (c),
          m_enabled (true) {}

    //-----------------------------------------------------------------------

    bool 
    write_delay_engine_t::set_write_delay (bool b) 
    { 
        bool ret = m_enabled;
        m_enabled = b; 
        return ret;
    }

    //-----------------------------------------------------------------------

    write_delay_engine_t::~write_delay_engine_t () {}

    //-----------------------------------------------------------------------

    write_delay_engine_t::node_t::node_t (file_id_t id, time_t t, str dat, 
                                          bool dirty)
        : m_fid (id), 
          m_filename (id.name ()), 
          m_file_time (t),
          m_data (dat), 
          m_store_time (sfs_get_timenow ()),
          m_dirty (dirty) {}

    //-----------------------------------------------------------------------

    bool 
    write_delay_engine_t::init ()
    {
        bool ret = engine_t::init ();
        flush_loop ();
        return ret;
    }

    //-----------------------------------------------------------------------

    tamed void
    write_delay_engine_t::shutdown_T (evv_t ev)
    {
        m_poke_ev->trigger ();
        m_shutdown_ev = ev;
    }

    //-----------------------------------------------------------------------

    tamed void
    write_delay_engine_t::flush_loop ()
    {
        tvars {
            write_delay_engine_t::node_t *n;
            time_t now;
            time_t diff;
            size_t n_out (0);
            rendezvous_t<bool> rv (__FILE__, __LINE__);
            bool window_has_room;
            bool reaped;
            ptr<bool> ap;
            time_t timeout;
            bool timeout_set (false);
        }

        ap = _alive;

        m_poke_ev = mkevent (rv, false);

        while ((n = m_queue.first) || n_out || !m_shutdown_ev) {

            now = sfs_get_timenow ();
            diff = n ? now - n->m_store_time : 0;
            timeout = m_shutdown_ev ? 0 : _cfg->write_delay ();
            window_has_room = (n_out < _cfg->write_delay_parallelism());

            if (n && !n->is_dirty ()) {
                m_queue.remove (n);
                m_tab.remove (n);
                delete n;

            } else if (n && window_has_room && diff >= timeout) {
                
                m_queue.remove (n);
                m_tab.remove (n);
                n_out++;

                // Will call delete(n) after it's done!
                n->store (this, mkevent (rv, true));

            } else {

                if (window_has_room && timeout && !timeout_set) {
                    assert (diff < timeout);
                    timeout -= diff;
                    delaycb (timeout, 0, mkevent (rv, false));
                    timeout_set = true;
                }

                twait (rv, reaped);
                if (reaped) {
                    assert (n_out > 0);
                    n_out --;
                } else {
                    timeout_set = false;
                }
            }
        }
        rv.cancel ();
        m_shutdown_ev->trigger ();
    }

    //=======================================================================
};
