
#include "dsdc_util.h"
#include "tst_prot.h"
#include "async.h"
#include "crypt.h"
#include "parseopt.h"
#include "rxx.h"
#include "dsdc_prot.h"
#include "dsdc_const.h"

typedef enum { NONE = 0,
               GET = 1,
               PUT = 2
             } tst_mode_t;

static void
hash_key (const tst_key_t &in, dsdc_key_t *k)
{
    sha1_hashxdr (k->base (), in);
}

static void
compute_checksum (tst_obj_checked_t *u)
{
    sha1_hashxdr (u->checksum.base (), u->obj);
}

static bool
check_obj (const tst_obj_checked_t *o)
{
    char digest[sha1::hashsize];
    sha1_hashxdr (digest, o->obj);
    return (memcmp (digest, o->checksum.base (), sha1::hashsize) == 0);
}

static void
generate_kv (tst_key_t *k, str *v)
{
    *k =  ( rand () % INT_MAX );

    mstr m (40);
    int shift = 0;
    u_int32_t w = 0;
    for (u_int i = 0 ; i < 40; i ++) {
        if (shift == 0)
            w = rand ();
        m[i] = (w >> shift) & 0xff;
        shift = (shift + 8 ) % 32;
    }
    *v = armor64 (m);
}

static bool
parse_kv (const str &in, tst_key_t *k, str *v)
{
    static rxx x ("([0-9]+),([0-9a-zA-Z_-]+)");
    if (!x.match (in))
        return false;
    if (!convertint (x[1], k))
        return false;
    *v = x[2];
    return true;
}

static void
usage ()
{
    warn << "usage: " << progname << " -p <key>,<value> host:port\n"
    << "       " << progname << " -g <key> host:port\n";
    exit (1);
}

class tst_cli_t {
public:
    tst_cli_t () : _port (0), _fd (-1) {}
    virtual ~tst_cli_t () {}
    void set_gw (const str &h, int p) { _hostname = h; _port = p; }
    virtual void do_cmd () = 0;
    void run ();
    void connect_cb (int f);

    void wrn (const str &s)
    { warn << _hostname << ":" << _port << ": " << s << "\n"; }

protected:
    str _hostname;
    int _port;
    int _fd;
    ptr<axprt_stream> _x;
    ptr<aclnt> _cli;
};

class get_cli_t : public tst_cli_t {
public:
    get_cli_t (const tst_key_t &k) : tst_cli_t (), _key (k) {}
    void do_cmd ();
    void do_cmd_cb (ptr<dsdc_get_res_t> res, clnt_stat err);
private:
    const tst_key_t _key;
};

class put_cli_t : public tst_cli_t {
public:
    put_cli_t (const tst_key_t &k, const str &v) :
            tst_cli_t (), _key (k), _value (v) {}
    void do_cmd () ;
    void do_cmd_cb (ptr<int> res, str mapping, clnt_stat err);
private:
    const tst_key_t _key;
    const str _value;
};

void
tst_cli_t::run ()
{
    tcpconnect (_hostname, _port, wrap (this, &tst_cli_t::connect_cb));
}

void
tst_cli_t::connect_cb (int f)
{
    if (f < 0) {
        wrn ("connection failed");
        exit (1);
    }
    _fd = f;
    _x = axprt_stream::alloc (_fd);
    _cli = aclnt::alloc (_x, dsdc_prog_1);

    do_cmd ();
}

void
get_cli_t::do_cmd_cb (ptr<dsdc_get_res_t> res, clnt_stat err)
{
    if (err) {
        warn << "RPC error: " << err << "\n";
        exit (1);
    } else if  (res->status != DSDC_OK) {
        warn << "Bad DSDC error code: " << res->status << "\n";
        exit (1);
    } else {
        tst_obj_checked_t obj;
        if (!bytes2xdr (obj, *res->obj)) {
            warn << "bytes2xdr failed!\n";
            exit (1);
        } else if (!check_obj (&obj)) {
            warn << "checksum on object failed!\n";
            exit (1);
        } else {
            printf ("%s\n", key_to_str (obj.checksum).cstr ());
            exit (0);
        }
    }
}

void
put_cli_t::do_cmd_cb (ptr<int> res, str mapping, clnt_stat err)
{
    if (err) {
        warn << "RPC error: " << err << "\n";
        exit (1);
    } else if (*res != DSDC_REPLACED && *res != DSDC_INSERTED) {
        warn << "DSDC error: " << *res << "\n";
        exit (1);
    } else {
        printf ("%s\n", mapping.cstr ());
        exit (0);
    }

}

void
put_cli_t::do_cmd ()
{
    dsdc_key_t outkey;
    dsdc_put_arg_t arg;
    hash_key (_key, &arg.key);

    tst_obj_checked_t obj;
    obj.obj.key = _key;
    obj.obj.val = _value;

    compute_checksum (&obj);
    if (! xdr2bytes (arg.obj, obj)) {
        warn << "xdr2bytes failed\n";
        exit (1);
    }

    strbuf mapping ("%d (%s) -> %s",
                    _key,
                    key_to_str (arg.key).cstr (),
                    key_to_str (obj.checksum).cstr ());

    ptr<int> res = New refcounted<int> ();
    _cli->call (DSDC_PUT, &arg, res,
                wrap (this, &put_cli_t::do_cmd_cb, res, str (mapping)));
}

void
get_cli_t::do_cmd ()
{
    dsdc_get_arg_t arg;
    hash_key (_key, &arg);

    ptr<dsdc_get_res_t> res = New refcounted<dsdc_get_res_t> ();
    _cli->call (DSDC_GET, &arg, res,
                wrap (this, &get_cli_t::do_cmd_cb, res));
}

int
main (int argc, char *argv[])
{
    int ch;
    tst_mode_t mode = NONE;
    tst_key_t key = 0;
    str value;

    tst_cli_t *cli = NULL;

    setprogname (argv[0]);

    while ((ch = getopt (argc, argv, "g:p:r")) != -1) {
        bool random = false;
        switch (ch) {
        case 'g':
            if (mode != NONE)
                usage ();
            mode = GET;
            if (!convertint (optarg, &key))
                usage ();
            cli = New get_cli_t (key);
            break;

        case 'r':
            srand (getpid ());
            random = true;
        case 'p':
            if (mode != NONE)
                usage ();
            if (random) {
                generate_kv (&key, &value);
            } else if (!parse_kv (optarg, &key, &value))
                usage ();
            mode = PUT;
            cli = New put_cli_t (key, value);
            break;
        default:
            usage ();
        }
    }

    str host = "localhost";
    int port = dsdc_port;
    if (optind == argc - 1) {
        if (!parse_hn (argv[optind], &host, &port))
            usage ();
    } else if (optind != argc)
        usage ();
    if (!cli)
        usage ();

    cli->set_gw (host, port);
    cli->run ();

    amain ();
}


