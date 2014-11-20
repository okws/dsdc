
#include "async.h"
#include "rxx.h"
#include "parseopt.h"
#include "dsdc_util.h"
#include "crypt.h"

str dsdc_hostname;
static int dsdc_debug_level = 0;

bool show_debug (int lev) { return (lev <= dsdc_debug_level); }
void set_debug (int l) { dsdc_debug_level = l; }

void
set_hostname (const str &h)
{
    if (h)
        dsdc_hostname = h;
    else
        dsdc_hostname = myname ();
}

hash_t
hash_hash (const dsdc_key_t &h)
{
    u_int *p = (u_int *)h.base ();
    const char *end_c = h.base () + h.size ();
    u_int *end_i = (u_int *)end_c;
    u_int r = 0;
    while (p < end_i)
        r = r ^ *p++;
    return r;
}

str
key_to_str (const dsdc_key_t &k)
{
    str in (k.base (), k.size ());
    return armor64 (in);
}

bool
parse_hn (const str &in, str *host, int *port)
{
    static rxx host_port_rxx ("([.0-9A-Za-z_-]*)(:[0-9]+)?");
    if (!host_port_rxx.match (in))
        return false;
    str h = host_port_rxx[1];
    if (h && h.len () > 0 && h != "-")
        *host = h;
    str p = host_port_rxx[2];
    if (p && p.len () > 1) {
        const char *pc = p.cstr () + 1;
        p = pc;
        if (!convertint (p, port))
            return false;
    }
    return true;
}

str
dsdc_app_t::progname (const str &in, bool usepid) const
{
    strbuf b (in);
    if (progname_xtra () && ::progname == "dsdc")
        b << progname_xtra ();
    if (_daemonize && usepid)
        b.fmt ("[%d]", getpid ());
    return b;
}

//-----------------------------------------------------------------------

bool 
is_empty_checksum (const dsdc_cksum_t &cksum)
{
    for (size_t i = 0; i < cksum.size (); i++) {
        if (cksum[i] != 0) { return false; }
    }
    return true;
}

//-----------------------------------------------------------------------

void make_empty_checksum (dsdc_cksum_t *out) 
{ memset (out->base (), 0, out->size ()); }

//-----------------------------------------------------------------------

bool check_checksum(const dsdc_obj_t& obj,
                    const dsdc_cksum_t* cksum) {
    dsdc_cksum_t tmp;
    return (sha1_hashxdr (tmp.base (), obj) &&
            memcmp (tmp.base (), cksum->base (), cksum->size()) == 0);
}

//-----------------------------------------------------------------------------

bool check_checksum(const void* obj, size_t len,
                    const dsdc_cksum_t* cksum) {
    dsdc_cksum_t tmp;
    sha1_hash( (void*) tmp.base (), obj, len);
    return (memcmp (tmp.base (), cksum->base (), cksum->size()) == 0);
}

//-----------------------------------------------------------------------------

