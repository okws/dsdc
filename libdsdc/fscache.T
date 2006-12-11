
// -*-c++-*-

#include "fscache.h"
#include "dsdc_prot.h"
#include "crypt.h"
#include "arpc.h"
#include "sha1.h"

namespace fscache {

//-----------------------------------------------------------------------

cfg_t::cfg_t ()
    : _backend (BACKEND_AIOD),
      _n_levels (3),
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
file_id_t::fullpath (int lev) const
{

#define SZ 32
    char buf[SZ];
    int rc = snprintf (buf, SZ, "%08x", _index);
#undef SZ

    assert (lev < rc);
    char tmp[2];
    const char *cp = buf;
    strbuf out;

    tmp[1] = 0;

    for (int i = 0; i < lev; i++) {
        tmp[0] = *cp++;
        out << tmp << "/";
    }
    out << _name;
    return out;
}

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

TAMED void
engine_t::load (file_id_t id, cbits_t cb)
{
    VARS {
        str fn;
        str out;
        time_t tm (0);
        str ret_str;
        int rc;
    }
    fn = filename (id);
    BLOCK { _backend->file2str (fn, @(rc, out)); }
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
    SIGNAL (cb, rc, tm, ret_str);
}

//-----------------------------------------------------------------------

TAMED void
engine_t::store (file_id_t id, time_t tm, str data, cbi cb)
{
    VARS {
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
        BLOCK { _backend->str2file (fn, out, _cfg->file_mode (), @(rc));}
    }
    SIGNAL (cb, rc);
}

//-----------------------------------------------------------------------

TAMED void
engine_t::remove (file_id_t id, cbi cb)
{
    VARS {
        str fn;
        int rc;
    }
    fn = filename (id);
    BLOCK { _backend->remove (fn, @(rc)); }
    SIGNAL (cb, rc);
}

//-----------------------------------------------------------------------

str
engine_t::filename (file_id_t id) const
{
    strbuf b;
    str s;
    b << _cfg->root ();
    b << "/" ;
    s = id.fullpath (_cfg->n_levels ());
    b << s;
    return b;
}

//-----------------------------------------------------------------------

void
simple_backend_t::file2str (str fn, cbis_t cb)
{
    str s = ::file2str (fn);
    if (s) {
        SIGNAL (cb, 0, s);
    } else {
        SIGNAL (cb, 0-errno, NULL);
    }
}

//-----------------------------------------------------------------------

void
simple_backend_t::str2file (str s, str f, int mode, cbi cb)
{
    bool b = ::str2file (f, s, mode);
    SIGNAL (cb, b ? 0-errno : 0);
}

//-----------------------------------------------------------------------

void
simple_backend_t::remove (str f, cbi cb)
{
    int rc = unlink (f.cstr ());
    SIGNAL (cb, rc == 0 ? 0 : 0 - errno);
}

//-----------------------------------------------------------------------

TAMED void
aiod_backend_t::file2str_T (str fn, cbis_t cb)
{
    VARS {
        int rc;
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
    BLOCK { _aiod->open (fn, O_RDONLY, 0, @(fh, rc)); }
    if (rc == 0) {
        BLOCK { fh->fstat (@(sb, rc)); }
        if (rc != 0) {
            warn << "fstat failed on file: " << fn << "\n";
        } else {
            sz = sb->st_size;
            if (!(buf = _aiod->bufalloc (blocksz))) {
                rc = -ENOMEM;
            } else {
                eof = false;
                for (pos = 0; pos < sz && rc == 0 && !eof; pos += rsz) {
                    BLOCK { fh->read (pos, buf, @(b2, rsz, rc)); }
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
    } else {
        rc = 0 - rc;
    }
    SIGNAL (cb, rc, ret);
}

//-----------------------------------------------------------------------

TAMED void
aiod_backend_t::str2file_T (str fn, str s, int mode, cbi cb)
{
    VARS {
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

    BLOCK { _aiod->open (fn, O_WRONLY|O_CREAT, mode, @(fh, rc)); }
    if (rc == 0) {
        if (!(buf = _aiod->bufalloc (blocksz))) {
            rc = ENOMEM;
        } else {
            for (pos = 0, cp = s.cstr (); cp < ep && rc == 0;
                 pos += blocksz, cp += blocksz) {
                bsz = min<ssize_t> (blocksz, ep - cp);
                memcpy (buf->base (), cp, bsz);
                BLOCK { fh->swrite (pos, buf, 0, bsz, @(b2, wsz, rc)); }
                if (rc != 0) {
                    warn ("Bad write to file (%s): %d\n", fn.cstr (), rc);
                } else if (wsz != bsz) {
                    warn ("Short write to file (%s): "
                          "expected %d bytes, got %d\n",
                          fn.cstr (), bsz, wsz);
                    rc = EIO;
                }
            }
        }
        BLOCK { fh->close (@(rc)); }
        if (rc != 0) {
            warn ("Close failed on file (%s): %d\n", fn.cstr (), rc);
        }
    }
    SIGNAL (cb, rc);
}

//-----------------------------------------------------------------------

TAMED void
aiod_backend_t::remove_T (str f, cbi cb)
{
    VARS {
        int rc;
    }
    BLOCK { _aiod->unlink (f, @(rc)); }
    SIGNAL (cb, rc);
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

};
