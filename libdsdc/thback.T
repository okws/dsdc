// -*- mode: c++; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil; -*-

#include <pthread.h>
#include "fscache.h"
#include "tame_io.h"

#ifndef __STDC_FORMAT_MACROS
# define __STDC_FORMAT_MACROS
#endif
#include <inttypes.h>

namespace fscache {

#define BUFSZ 64
    //-----------------------------------------------------------------------

#define CI "zu"

#define TWARN0(fmt)                             \
    fprintf (stderr, "%s: TXX[%" CI "] " fmt, progname.cstr (), cell->_id)
#define TWARN(fmt, ...)                                                 \
    fprintf (stderr, "%s: TXX[%" CI "] " fmt, progname.cstr (), cell->_id,  \
             __VA_ARGS__)

    //-----------------------------------------------------------------------

    typedef thread_backend_t::out_t out_t;
    typedef thread_backend_t::in_t in_t;
    typedef thread_backend_t::cell_t cell_t;

#if HAVE_DSDC_PTHREAD

    //-----------------------------------------------------------------------

    int
    th_file2str (cell_t *cell, str file, str *out)
    {
        int rc = -1;
        int fd = open (file, O_RDONLY, 0);
        if (fd < 0) {
            rc = -errno;
        } else {
            struct stat sb;
            if (fstat (fd, &sb) < 0) {
                close (fd);
                rc = -errno;
            } else if (!S_ISREG (sb.st_mode)) {
                TWARN ("%s: not a regular file\n", file.cstr ());
                close (fd);
                rc = -EINVAL;
            } else { 
                mstr m (sb.st_size);
                errno = EAGAIN;
                ssize_t n = read (fd, m, sb.st_size);
                int saved_errno = errno;
                close (fd);
                errno = saved_errno;
                if (n < 0) {
                    rc = -errno;
                } else {
                    rc = 0;
                    m.setlen (n);
                    *out = m;
                }
            }
        }
        return rc;
    }

    //-----------------------------------------------------------------------

    static int
    th_str2file (cell_t *cell, str fn, str s, int mode, bool canfail)
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
                    TWARN ("write failed on file %s: %s\n", fnc, 
                           strerror (errno));
                } else if (rc == 0) {
                    TWARN ("unexpected 0-length write on file %s\n", fnc);
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
                TWARN ("open on file '%s' failed: %s\n", fnc, 
                       strerror (errno));
            }
        }
        return (0 - rc);
    }

    //-----------------------------------------------------------------------


    bool
    handle_event (cell_t *cell)
    {
        typedef simple_fast_backend_t sb;
        bool ret = true;
        int rc = 0;
        const in_t &in = cell->_in;

        switch (cell->_in._op) {
        case thread_backend_t::OP_FILE2STR: 
            rc = th_file2str (cell, in._path, &cell->_out._data);
            break;
        case thread_backend_t::OP_STR2FILE:
            rc = th_str2file (cell, in._path, in._data, in._mode, in._can_fail);
            break;
        case thread_backend_t::OP_REMOVE:
            rc = sb::s_remove (in._path);
            break;
        case thread_backend_t::OP_STATVFS:
            rc = sb::s_statvfs (in._path, &cell->_out._statvfs);
            break;
        case thread_backend_t::OP_MKDIR:
            rc = sb::s_mkdir (in._path, in._mode);
            break;
        case thread_backend_t::OP_SHUTDOWN:
            ret = false;
            break;
        case thread_backend_t::OP_STAT:
            rc = sb::s_stat (in._path, &cell->_out._stat);
            break;
        }
        cell->_out._rc = rc;

        if (cell->_cfg->debug(DEBUG_OP_TRACE)) {
            str p = in._path;
            if (!p) { p = "<null>"; }
            TWARN("op-trace: op=%d; file=%s; rc=%d\n",
                  int (cell->_in._op), p.cstr (), rc);
        }

        return ret;
    }
    
    //-----------------------------------------------------------------------

    static void
    thread_run (cell_t *cell)
    {
        char buf[BUFSZ];
        bool go = true;
        int rc, len;
       
        while (go) {
            rc = read (cell->_thread_fd, buf, BUFSZ);
            go = false;
            if (rc < 0 && errno != EAGAIN) {
                TWARN ("read failed: %s\n", strerror (errno));
            } else if (rc == 0) {
                TWARN0 ("EOF on thread\n");
            } else if (rc != 1) {
                TWARN ("expected one byte, but got %d!\n", rc);
            } else {
                go = handle_event (cell);
                len = sprintf (buf, "1");

                while ((rc = write (cell->_thread_fd, buf, rc)) < 0 &&
                       errno == EAGAIN) {}
                
                if (rc < 0) {
                    TWARN ("write returned an error: %s\n", strerror (errno));
                    go = false;
                } else if (rc != len) {
                    TWARN ("got short write: %d v %d\n", len, rc);
                    go = false;
                }
            }
        }
        TWARN0 ("thread exiting!\n");
        close (cell->_thread_fd);
        cell->_thread_fd = -1;
        cell->_alive = false;
        pthread_exit (NULL);
    }
    
    //-----------------------------------------------------------------------
    
    static void * thread_run_v (void *v) 
    { thread_run (reinterpret_cast<cell_t *> (v)); return NULL; }

#endif /* HAVE_DSDC_PTHREAD */
            
    //-----------------------------------------------------------------------
            
    thread_backend_t::thread_backend_t (const cfg_t *c) 
        : backend_t (), 
          _cfg (c),
          _n_threads (c->_n_aiods > 0 ? c->_n_aiods : 1),
          _alive (New refcounted<bool> (true)) {}

    //-----------------------------------------------------------------------

    thread_backend_t::~thread_backend_t () { *_alive = false; }

    //-----------------------------------------------------------------------

    bool
    thread_backend_t::mkthread (size_t i, cell_t *slot)
    {
        bool ret = true;
        int fds[2];
        int rc = socketpair (AF_UNIX, SOCK_STREAM, 0, fds);
        if (rc < 0) {
            warn ("socketpair failed: %m\n");
            ret = false;
        } else {
            memset ((void *)slot, 0, sizeof (slot));
            slot->_id = i;
            slot->_alive = true;
            slot->_main_fd = fds[0];
            slot->_cfg = _cfg;
            make_async (fds[0]);
            slot->_thread_fd = fds[1];

#if HAVE_DSDC_PTHREAD
            pthread_attr_t attr;
            pthread_attr_init (&attr);
            pthread_attr_setstacksize (&attr, 10*1024*1024);
            int rc = pthread_create (&slot->_thread, &attr, 
                                     thread_run_v, slot);
            if (rc != 0) {
                warn ("pthread_create failed: %m\n");
                ret = false;
            } else {
                return_thread (i);
            }
#else /* HAVE_DSDC_PTHREAD */
            warn ("cannot run pthread backend without pthread support\n");
            ret = false;
#endif /* HAVE_DSDC_PTHREAD */
        }
        return ret;
    }

    //-----------------------------------------------------------------------

    bool
    thread_backend_t::init ()
    {
        bool ret = true;
        _threads.setsize (_n_threads);
        for (size_t i = 0; i < _n_threads; i++) {
            if (!mkthread (i, &_threads[i])) {
                ret = false;
            }
        }
        
        // run a background loop to fix any broken threads!
        if (ret) {
            fix_threads ();
        }
        return ret;
    }

    //-----------------------------------------------------------------------

    bool 
    thread_backend_t::fire_off (cell_t *cell)
    {
        char buf[BUFSZ];
        int dlen = sprintf (buf, "1");
        int rc = write (cell->_main_fd, buf, dlen);
        bool ret = false;
        if (rc < 0) {
            warn ("XX[%" CI "] write failure: %m\n", cell->_id);
        } else if (rc != dlen) {
            warn ("XX[%" CI "] wrong-sized write: len=%d (v %d)\n", 
                  cell->_id, rc, dlen);
        } else {
            ret = true;
        }
        return ret;
    }

    //-----------------------------------------------------------------------

    tamed void
    thread_backend_t::harvest (cell_t *cell, evb_t ev)
    {
        tvars {
            int rc (0);
            char buf[BUFSZ];
            bool go (true);
            size_t id;
        }
        id = cell->_id;

        while (go) {
            twait { tame::waitread (cell->_main_fd, mkevent ()); }
            rc = read (cell->_main_fd, buf, BUFSZ);
            go = false;
            if (rc == 0) {
                warn ("XX[%" CI "] EOF on thread\n", id);
            } else if (rc != 1) {
                warn ("XX[%" CI "] wrong number of bytes back: %d\n", id, rc);
            } else if (rc < 0 && errno == EAGAIN) {
                go = true;
                /* go again */
            } else if (rc < 0) {
                warn ("XX[%" CI "] unexpected read failure: %m", id);
            }
        }
        ev->trigger (rc > 0);
    }

    //-----------------------------------------------------------------------

    tamed void
    thread_backend_t::grab_thread (ev_sz_t ev)
    {
        tvars {
            size_t ret;
        }
        twait { _lock.acquire (tame::lock_t::EXCLUSIVE, mkevent ()); }
        while (!_ready_q.size ()) {
            twait { _waiter_ev = mkevent (); }
        }
        ret = _ready_q.pop_back ();
        _lock.release ();
        ev->trigger (ret);
    }

    //-----------------------------------------------------------------------

    void
    thread_backend_t::return_thread (size_t i)
    {
        _ready_q.push_back (i);
        if (_waiter_ev) {
            evv_t::ptr tmp = _waiter_ev;
            _waiter_ev = NULL;
            tmp->trigger ();
        }
    }

    //-----------------------------------------------------------------------

    static int
    fix_rc (bool ok, const out_t &out)
    {
        return ok ? out._rc : -EINVAL;
    }

    //-----------------------------------------------------------------------

    tamed void
    thread_backend_t::statvfs_T (str d, struct statvfs *buf, evi_t ev)
    {
        tvars {
            in_t in;
            out_t out;
            bool ok;
        }
        in._op = OP_STATVFS;
        in._path = d;
        twait { execute (in, &out, mkevent (ok)); }
        if (ok) { *buf = out._statvfs; }
        ev->trigger (fix_rc (ok, out));
    }

    //-----------------------------------------------------------------------

    tamed void
    thread_backend_t::file2str_T (str fn, evis_t ev)
    {
        tvars {
            in_t in;
            out_t out;
            bool ok;
            str dat;
        }
        in._op = OP_FILE2STR;
        in._path = fn;
        twait { execute (in, &out, mkevent (ok)); }
        if (ok) { dat = out._data; }
        ev->trigger (fix_rc (ok, out), dat);
    }

    //-----------------------------------------------------------------------
    
    tamed void
    thread_backend_t::remove_T (str f, evi_t ev)
    {
        tvars {
            in_t in;
            out_t out;
            bool ok;
        }
        in._op = OP_REMOVE;
        in._path = f;
        twait { execute (in, &out, mkevent (ok)); }
        ev->trigger (fix_rc (ok, out));
    }

    //-----------------------------------------------------------------------

    tamed void
    thread_backend_t::stat_T (str f, struct stat *sb, evi_t ev)
    {
        tvars {
            in_t in;
            out_t out;
            bool ok;
        }
        in._op = OP_STAT;
        in._path = f;
        twait { execute (in, &out, mkevent (ok)); }
        ev->trigger (fix_rc (ok, out));
    }


    //-----------------------------------------------------------------------

    tamed void
    thread_backend_t::mkdir_T (str f, int mode, evi_t ev)
    {
        tvars {
            in_t in;
            out_t out;
            bool ok;
        }
        in._op = OP_MKDIR;
        in._path = f;
        in._mode = mode;
        twait { execute (in, &out, mkevent (ok)); }
        ev->trigger (fix_rc (ok, out));
    }

    //-----------------------------------------------------------------------

    tamed void
    thread_backend_t::str2file_inner_T (str f, str s, int md, bool cf, evi_t ev)
    {
        tvars {
            in_t in;
            out_t out;
            bool ok;
        }
        in._op = OP_STR2FILE;
        in._path = f;
        in._data = s;
        in._mode = md;
        in._can_fail = cf;
        twait { execute (in, &out, mkevent (ok)); }
        ev->trigger (fix_rc (ok, out));
    }

    //-----------------------------------------------------------------------

    tamed void
    thread_backend_t::execute (const in_t &in, out_t *out, evb_t ev)
    {
        tvars {
            cell_t *cell;
            size_t id;
            bool ok;
        }

        twait { grab_thread (mkevent (id)); }
        cell = &_threads[id];
        cell->_in = in;

        ok = fire_off (cell);
        if (ok) {
            twait { harvest (cell, mkevent (ok)); }
            if (!ok) {
                warn ("XX[%" CI "] failed to harvest thread\n", id);
            } else {
                *out = cell->_out;
            }
        } else {
            warn ("XX[%" CI "] failed to fire thread\n", id);
        }

        ev->trigger (ok);

        if (!ok) { kill_thread (cell); }
        else { return_thread (id); }
    }

    //-----------------------------------------------------------------------

    void thread_backend_t::kill_thread (cell_t *cell)
    { 
        // Closing our FD should get that guy to leave his loop.
        close (cell->_main_fd);
        cell->_main_fd = -1;
    }

    //-----------------------------------------------------------------------

    tamed void
    thread_backend_t::fix_threads ()
    {
        tvars {
            int w (1);
            ptr<bool> alive;
            size_t i;
        }
        alive = _alive;

        while (*alive) {
            twait { delaycb (w, 0, mkevent ()); }
            for (i = 0; i < _threads.size (); i++) {
                cell_t *cell = &_threads[i];
                if (cell->_alive) { /* ok! */ } 
                else if (!mkthread (i, cell)) {
                    warn ("XX[%" CI "] failed to make new thread; "
                          "will retry in %ds\n", i, w);
                } else {
                    warn ("XX[%" CI "] recovered thread\n", i);
                }
            }
        }
    }

    //-----------------------------------------------------------------------

};
