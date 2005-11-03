/*
 * $Id$
 */

%#define MATCHD_FRONTD_FROBBER	0
%#define MATCHD_FRONTD_USERCACHE_FROBBER	1
%#define UBER_USER_FROBBER	2
%#define PROFILE_STALKER_FROBBER	3

/* %#include "userid_prot.h" */

struct matchd_frontd_userkey_t {
	int frobber;		/**< should always be MATCHD_FRONTD_FROBBER */
	u_int64_t userid;	/**< user id */
};

struct uber_key_t {
	int frobber;		/**< should always be UBER_USER_FROBBER */
	u_int64_t userid;	/**< user id */
	unsigned int load_type; /**< load type; see uberconst.h */
};

/**
 * generic dsdc key for various user-related stuff
 * Be sure to use different frobber values.
 */
struct user_dsdc_key_t {
	int frobber;		/**< unique ID for data type */
	u_int64_t userid;	/**< user id */
};

/*
 * Matchd question.  This matches the qanswers table in our database.
 */
struct matchd_qanswer_row_t {
	int questionid;
	int answer;		/**< actual answer 0-4 */
	int match_answer;	/**< wanted answers mask */
	int importance;		/**< importance */
	int date_answered;	/**< time_t answered. */
	int skipped;		/**< question skipped? */
};

typedef matchd_qanswer_row_t matchd_qanswer_rows_t<>;

#if 0
struct matchd_qanswer_compact_row_t {
    int questionid;
    int date_answered;
    int data;	/* bits: 0-1 answer, 2-5 answer mask, 6-8 importance */
}
#endif

/*
 * This structure is passed to the DSDC backend for computing matches.
 * it contains the questions for the user doing the comparison and the
 * userids on the backend server to compare against.
 */
struct matchd_frontd_dcdc_arg_t {
	matchd_qanswer_rows_t user_questions;
	u_int64_t userids<>;
};

/*
 * This is the per-user match result.
 */
struct matchd_frontd_match_datum_t {
	u_int64_t userid;	/**< user id */
	bool match_found;	/**< is median/deviation valid? */
	int mpercent;		/**< match percentage. */
	int fpercent;		/**< friend percentage. */
	int epercent;		/**< enemy percentage. */
};

/*
 * structure containing per-user match results.
 */
struct match_frontd_match_results_t {
	matchd_frontd_match_datum_t results<>;
};


%#define DSDC_KEYSIZE 20
%#define DSDC_DEFAULT_PORT 30002

typedef opaque dsdc_key_t[DSDC_KEYSIZE];

typedef dsdc_key_t dsdc_keyset_t<>;

typedef opaque dsdc_custom_t<>;

struct dsdc_key_template_t {
	unsigned id;
	unsigned pid;
	unsigned port;
	string hostname<>;
};

enum dsdc_res_t {
	DSDC_OK = 0,
	DSDC_REPLACED = 1,
	DSDC_INSERTED = 2,
	DSDC_NOTFOUND = 3,
	DSDC_NONODE = 4,
	DSDC_ALREADY_REGISTERED = 5,
	DSDC_RPC_ERROR = 6,
	DSDC_DEAD = 7,
	DSDC_LOCKED = 8,
	DSDC_TIMEOUT = 9
};

typedef opaque dsdc_obj_t<>;

struct dsdc_put_arg_t {
	dsdc_key_t key;
	dsdc_obj_t obj;
};

union dsdc_get_res_t switch (dsdc_res_t status) {
case DSDC_OK:
  dsdc_obj_t obj;
case DSDC_RPC_ERROR:
  unsigned err;
default:
  void;
};


/**
 * a series of name/value pairs for a multi-get (mget)
 */
struct dsdc_mget_1res_t {
  dsdc_key_t key;
  dsdc_get_res_t res;
};

typedef dsdc_mget_1res_t dsdc_mget_res_t<>;
typedef dsdc_key_t       dsdc_mget_arg_t<>;


struct dsdcx_slave_t {
 	dsdc_keyset_t keys;
	string hostname<>;
	int port;
};

struct dsdcx_state_t {
	dsdcx_slave_t slaves<>;
	dsdcx_slave_t *lock_server;
};

struct dsdc_register_arg_t {
 	dsdcx_slave_t slave;
	bool primary;
	bool lock_server;
};


union dsdc_getstate_res_t switch (bool needupdate) {
case true:
	dsdcx_state_t state;
case false:
	void;
};

union dsdc_lock_acquire_res_t switch (dsdc_res_t status) {
case DSDC_OK:
	unsigned hyper lockid;
case DSDC_RPC_ERROR:
	unsigned err;
default:
	void;
};

struct dsdc_lock_acquire_arg_t {
	dsdc_key_t key;           // a key into a lock-specific namespace
        bool writer;              // if shared lock, if needed for writing
	bool block;               // whether to block or just fail
	unsigned timeout;         // how long the lock is held for
};

struct dsdc_lock_release_arg_t {
	dsdc_key_t key;	          // original key that was locked
	unsigned hyper lockid;    // provide the lock-ID to catch bugs

};


program DSDC_PROG 
{
	version DSDC_VERS {
	
		void
		DSDC_NULL (void) = 0;

/*
 * these are the only 4 calls that clients should use.  they should
 * issue them to the master nodes, who will deal with them:
 *
 *  PUT / REMOVE / GET / MGET
 * 
 */
		dsdc_res_t
		DSDC_PUT (dsdc_put_arg_t) = 1;

		dsdc_res_t
		DSDC_REMOVE (dsdc_key_t) = 2;
		
		dsdc_get_res_t
		DSDC_GET (dsdc_key_t) = 3;

		dsdc_mget_res_t
		DSDC_MGET (dsdc_mget_arg_t) = 4;


/*
 * the following 4 calls are for internal management, that dsdc
 * uses for itself:
 *
 *   REGISTER / HEARTBEAT / NEWNODE / GETSTATE
 */

		/*
   		 * a slave node should register with all master nodes
		 * using this call.  It should register as many keys
		 * in the keyspace as it wants to service.  The more
		 * keys, the more of the load it will see. 
		 * Should set the master flag in the arg structure
		 * only once; the master will broadcast the insertion
		 * to the other nodes in the ring.
		 */
		dsdc_res_t	
		DSDC_REGISTER (dsdc_register_arg_t) = 6;

		/*
 		 * heartbeat;  a slave must send a periodic heartbeat
	  	 * message, otherwise, the master will think it's dead.
		 */
		dsdc_res_t
		DSDC_HEARTBEAT (void) = 7;

		/*
		 * when a new node is inserted, the master broadcasts
		 * all of the other nodes, alerting them to clean out
		 * their caches.  this is also when we would add
		 * data movement protocols.
		 */
		dsdc_res_t
		DSDC_NEWNODE (dsdcx_slave_t) = 8;

		/*
		 * nodes should periodically get the complete system
		 * state and clean out their caches accordingly.
		 */
		dsdc_getstate_res_t	
		DSDC_GETSTATE (dsdc_key_t) = 9;


/*
 * Simple locking primitives for doing synchronization via dsdc
 */

		/*
		 * Acquire a lock.
		 */
		dsdc_lock_acquire_res_t
		DSDC_LOCK_ACQUIRE (dsdc_lock_acquire_arg_t) = 10;


		/*
		 * Relase a lock that was granted.
 		 */
		dsdc_res_t
		DSDC_LOCK_RELEASE (dsdc_lock_release_arg_t) = 11;

/*
 *-----------------------------------------------------------------------
 * Below are custom RPCs for matching and okcupid-related functions
 * in particular (with procno >= 100...)
 *
 */
		match_frontd_match_results_t
                DSDC_COMPUTE_MATCHES(matchd_frontd_dcdc_arg_t) = 100;

	} = 1;
} = 30002;
