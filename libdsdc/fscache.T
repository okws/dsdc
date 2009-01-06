// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include "fscache.h"
#include "dsdc_prot.h"
#include "crypt.h"
#include "arpc.h"
#include "sha1.h"

#ifndef TRIGGER
#define TRIGGER(x,...) (*cb)(__VA_ARGS__)
#endif

namespace fscache {

//-----------------------------------------------------------------------

    cfg_t::cfg_t ()
            : _backend (BACKEND_AIOD),
            _n_levels (3),
            _n_dig (1),
            _root ("/disk/fscache"),
            _n_aiods (5),
            _shmsize (0x200000),
            _maxbuf (0x10000),
            _blocksz (0x4000),
            _file_mode (0664)
    {
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

    engine_t::engine_t (const cfg_t *c) : _cfg (c)
    {
        switch (c->backend ()) {
        case BACKEND_SIMPLE:
            _backend = New simple_backend_t ();
            break;
        case BACKEND_AIOD:
            _backend = New aiod_backend_t (c);
            break;
        default:
            panic ("Unknown backend given: %d\n", int (c->backend ()));
            break;
        }
    }

//-----------------------------------------------------------------------

    engine_t::~engine_t ()
    {
        delete _backend;
    }

//-----------------------------------------------------------------------

    tamed void
    engine_t::load (file_id_t id, cbits_t cb)
    {
        tvars {
            str fn;
            str out;
            time_t tm (0);
            str ret_str;
            int rc;
        }
        fn = filename (id);
        twait { _backend->file2str (fn, mkevent (rc, out)); }
        if (rc == 0) {
            fscache_file_t file;
            char digest[SHA1SZ];
            if (!str2xdr (file, out)) {
                warn ("Cannot decode file: %s\n", fn.cstr ());
                rc = -EINVAL;
            } else if (!sha1_hashxdr (digest, file.data)) {
                warn ("Cannot hash data from file: %s\n", fn.cstr ());
                rc = -EINVAL;
            } else if (memcmp (file.checksum.base (), digest, SHA1SZ) != 0) {
                warn ("Bad checksum on file: %s\n", fn.cstr ());
                rc = -EINVAL;
            } else {
                tm = file.data.timestamp;
                mstr m (file.data.data.size ());
                memcpy (m.cstr(), file.data.data.base (), file.data.data.size ());
                ret_str = m;
            }
        }
        TRIGGER (cb, rc, tm, ret_str);
    }

//-----------------------------------------------------------------------

    tamed void
    engine_t::store (file_id_t id, time_t tm, str data, cbi cb)
    {
        tvars {
            str fn;
            int rc;
            fscache_file_t file;
            str out;
        }
        fn = filename (id);
        file.data.timestamp = tm;
        file.data.data = data;
        if (!sha1_hashxdr (file.checksum.base (), file.data)) {
            warn ("Cannot compute checksum for file: %s\n", fn.cstr ());
            rc = -EINVAL;
        } else if (!(out = xdr2str (file))) {
            warn ("Cannot convert file to XDR form: %s\n", fn.cstr ());
            rc = -EINVAL;
        } else {
            twait { _backend->str2file (fn, out, _cfg->file_mode (), mkevent (rc));}
        }
        TRIGGER (cb, rc);
    }

//-----------------------------------------------------------------------

    tamed void
    engine_t::remove (file_id_t id, cbi cb)
    {
        tvars {
            str fn;
            int rc;
        }
        fn = filename (id);
        twait { _backend->remove (fn, mkevent (rc)); }
        TRIGGER (cb, rc);
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
    simple_backend_t::file2str (str fn, cbis_t cb)
    {
        str s = ::file2str (fn);
        if (s) {
            TRIGGER (cb, 0, s);
        } else {
            TRIGGER (cb, 0-errno, NULL);
        }
    }

//-----------------------------------------------------------------------

    void
    simple_backend_t::str2file (str fn, str s, int mode, evi_t ev)
    {
        bool b = ::str2file (fn, s, mode);
        int rc = 0;
        if (!b) {
            rc = (errno > 0) ? -errno : -EIO;
        }
        ev->trigger (rc);
    }

//-----------------------------------------------------------------------

    void
    simple_backend_t::remove (str f, cbi cb)
    {
        int rc = unlink (f.cstr ());
        TRIGGER (cb, rc == 0 ? 0 : 0 - errno);
    }

//-----------------------------------------------------------------------

    tamed void
    aiod_backend_t::file2str_T (str fn, cbis_t cb)
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
        TRIGGER (cb, rc, ret);
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
        }
        blocksz = _cfg->blocksz ();

        twait {
            _aiod->open (fn, O_WRONLY|O_CREAT, mode, mkevent (fh, rc));
        }

        // Remember: DM's aio library returns errnos in the
        // positive space, so check against that here..
        if (rc == ENOENT) {
            twait { mk_parent_dirs (fn, 0777, mkevent (rc)); }
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
    aiod_backend_t::remove_T (str f, cbi cb)
    {
        tvars {
            int rc;
        }
        twait { _aiod->unlink (f, mkevent (rc)); }
        TRIGGER (cb, rc);
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
        }

        memcpy (dir.cstr (), s.cstr (), s.len () + 1);
        bp = ep = dir.cstr ();

        for (  ; *ep && rc == 0; ep++) {
            if (*ep == '/') {
                *ep = 0;
                twait { mkdir (bp, mode, mkevent (rc)); }
                if (rc == -EEXIST) {
                    rc = 0;
                } else if (rc != 0) {
                    errno = -rc;
                    warn ("could not make directory %s: %m\n", bp);
                }
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
        ev->trigger (rc);
    }

//-----------------------------------------------------------------------

    void
    simple_backend_t::mkdir (str d, int mode, evi_t ev)
    {
        int rc = ::mkdir (d.cstr (), mode);
        if (rc != 0) rc = -errno;
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

        if (_cfg && _cfg->_root) { d = _cfg->_root; }
        else { d = "."; }

        twait { _backend->statvfs (d, buf, mkevent (rc)); }
        ev->trigger (rc);
    }

    //-----------------------------------------------------------------------

    void
    simple_backend_t::statvfs (str d, struct statvfs *buf, evi_t ev)
    {
        int rc = ::statvfs (d.cstr (), buf);
        if (rc != 0) rc = -errno;
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

};
