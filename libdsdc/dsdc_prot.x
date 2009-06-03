/*
 * $Id$
 */

#ifndef DSDC_NO_CUPID

enum ok_frobber_t {
	// For question data loaded into match.
	MATCHD_FRONTD_FROBBER =	0,            
	// For user information loaded into match  
	MATCHD_FRONTD_USERCACHE_FROBBER = 1,
	UBER_USER_OLD_FROBBER = 2,
	PROFILE_STALKER_FROBBER = 3,
	MATCHD_FRONTD_MATCHCACHE_FROBBER = 4, // For cached match results.
	GROUP_INFO_FROBBER = 5,
	GTEST_SCORE_FROBBER = 6, 	      // For generic test scores.
	PTEST_SCORE_FROBBER = 7,
	MTEST_SCORE_FROBBER = 8,
	CUPID_TEST_SCORE_FROBBER = 9,
	GTEST_SESSION_FROBBER =	10,
	PTEST_SESSION_FROBBER =	11,
	MTEST_SESSION_FROBBER =	12,
	MTEST_METADATA_FROBBER	= 13,
	MTEST_STATS_FROBBER = 14,
	SETTINGS_FROBBER = 15,
	PROFILE_FUZZY_MATCHES_FROBBER = 16,
	AD_KEYWORD_FROBBER = 17
    // ADD NO MORE FROBBERS!
    // Instead, add an entry in the dsdc::frobber function in dsdcMgr.C
};

typedef int dsdc_id_t;
typedef unsigned dsdc_statval_t; 
typedef unsigned hyper dsdc_big_statval_t;


/* %#include "userid_prot.h" */

/* 64 bit key */
struct dsdc_key64_t {
	uint32_t frobber;
	u_int64_t key64;	/**< user id */
};

/**
 * Identifier for most uber user structs.
 */
struct uber_key_t {
    u_int32_t frobber;
    u_int64_t userid;
    unsigned int load_type;
};

%#define MATCHD_NULL_QUESTION_ID	0

/*
 * Matchd question.  This matches the qanswers table in our database.
 */
struct matchd_qanswer_row_t {
	int questionid;
	unsigned int data;      /**< bits: 0-1 answer, 2-5 answer mask,
				  6-8 importance */
};

typedef matchd_qanswer_row_t matchd_qanswer_rows_t<>;

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
    int cache_misses;
	matchd_frontd_match_datum_t results<>;
};

#endif /* !DSDC_NO_CUPID */


%#define DSDC_KEYSIZE 20
%#define DSDC_DEFAULT_PORT 30002

typedef opaque dsdc_key_t[DSDC_KEYSIZE];

typedef dsdc_key_t dsdc_keyset_t<>;

enum dsdc_res_t {
  DSDC_OK = 0,			/* All good. */
  DSDC_REPLACED = 1,            /* Insert succeeded; object replaced */
  DSDC_INSERTED = 2,            /* Insert succeeded; object created */
  DSDC_NOTFOUND = 3,		/* Key lookup failed. */
  DSDC_NONODE = 4,              /* No slave nodes found in the ring */
  DSDC_ALREADY_REGISTERED = 5,  /* Second attempt to register */
  DSDC_RPC_ERROR = 6,           /* RPC communication error */
  DSDC_DEAD = 7,                /* Node was found, but is DEAD */
  DSDC_LOCKED = 8,              /* In advisory locking, acquire failed */
  DSDC_TIMEOUT = 9,             /* Not used yet.... */
  DSDC_ERRDECODE = 10,		/* Error decoding object. */
  DSDC_ERRENCODE = 11,		/* Error encoding object. */
  DSDC_BAD_STATS = 12,          /* Error in statistics collection */
  DSDC_DATA_CHANGED = 13,       /* checksum commit precondition failed */
  DSDC_DATA_DISAPPEARED = 14    /* as above, but data disappeared */
};

/*
 *=======================================================================
 * DSDC Statistics Structures
 */

enum dsdc_annotation_type_t {
	DSDC_NO_ANNOTATION = 0,
#ifndef DSDC_NO_CUPID
	DSDC_CUPID_ANNOTATION = 1,
#endif /* DSDC_NO_CUPID */
	DSDC_INT_ANNOTATION = 2,
	DSDC_STR_ANNOTATION = 3
};

union dsdc_annotation_t switch (dsdc_annotation_type_t typ) {
case DSDC_INT_ANNOTATION:
	int i;
#ifndef DSDC_NO_CUPID
case DSDC_CUPID_ANNOTATION:
	ok_frobber_t frobber;
#endif /* DSDC_NO_CUPID */
case DSDC_STR_ANNOTATION:
     string s<>;
default:
	void;
};


struct dsdc_histogram_t {
	hyper           scale_factor;
	unsigned	samples;
	hyper		avg;
	hyper		min;
	hyper		max;
	unsigned	buckets<>;
	hyper 		total;
};

struct dsdc_dataset_t {
	hyper creations;
	hyper puts;
	hyper missed_gets;
	hyper missed_removes;
	hyper rm_explicit;
	hyper rm_make_room;
	hyper rm_clean;
	hyper rm_replace;
	unsigned duration;
	dsdc_histogram_t gets;
	dsdc_histogram_t objsz;
	dsdc_histogram_t do_gets;
	dsdc_histogram_t do_lifetime;
	dsdc_histogram_t do_objsz;
	dsdc_histogram_t *lifetime; /* not useful on a per-epoch basis */
	hyper *n_active;            /* ditto */
};

struct dsdc_statistic_t {
	dsdc_annotation_t annotation;
	dsdc_dataset_t  epoch_data;
	dsdc_dataset_t  alltime_data;
};

typedef dsdc_statistic_t dsdc_statistics_t<>;

struct dsdc_dataset_params_t {
	unsigned lifetime_n_buckets;
	unsigned gets_n_buckets;
	unsigned objsz_n_buckets;
};

struct dsdc_get_stats_single_arg_t {
	dsdc_dataset_params_t params;
};

typedef string dsdc_hostname_t<>;
typedef dsdc_hostname_t dsdc_hostnames_t<>;

enum dsdc_settype_t {
	DSDC_SET_NONE = 0,
	DSDC_SET_ALL = 1,
	DSDC_SET_SOME = 2,
	DSDC_SET_RANDOM = 3,
	DSDC_SET_FIRST = 4
};

union dsdc_slaveset_t switch (dsdc_settype_t typ) {
case DSDC_SET_SOME:
	dsdc_hostnames_t some;
default: 
	void;
};

struct dsdc_get_stats_arg_t {
	dsdc_slaveset_t              hosts;
	dsdc_get_stats_single_arg_t  getparams;
};

union dsdc_get_stats_single_res_t switch (dsdc_res_t status) {
case DSDC_OK:
	dsdc_statistics_t stats;
default:
	void;
};

struct dsdc_slave_statistic_t {
	dsdc_hostname_t   host;
	dsdc_get_stats_single_res_t stats;
};

typedef dsdc_slave_statistic_t dsdc_slave_statistics_t<>;

/*
 * End statistic structures
 *=======================================================================
 */

struct dsdc_req_t {
    dsdc_key_t key;
    int time_to_expire;
};

typedef opaque dsdc_custom_t<>;

struct dsdc_key_template_t {
	unsigned id;
	unsigned pid;
	unsigned port;
	string hostname<>;
};

typedef opaque dsdc_obj_t<>;

struct dsdc_put_arg_t {
	dsdc_key_t 		key;
	dsdc_obj_t 		obj;
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
typedef dsdc_req_t       dsdc_mget2_arg_t<>;

typedef dsdc_key_t dsdc_get_arg_t;

struct dsdc_get3_arg_t {
	dsdc_key_t 	   key;
    	int 		   time_to_expire;
	dsdc_annotation_t  annotation;
};
typedef dsdc_get3_arg_t dsdc_mget3_arg_t<>;

struct dsdc_put3_arg_t {
	dsdc_key_t 		key;
	dsdc_obj_t 		obj;
	dsdc_annotation_t  annotation;
};

typedef dsdc_key_t dsdc_cksum_t;

struct dsdc_put4_arg_t {
	dsdc_key_t 		key;
	dsdc_obj_t 		obj;
	dsdc_annotation_t       annotation;
	dsdc_cksum_t		*checksum;
};

struct dsdc_remove3_arg_t {
	dsdc_key_t	   key;
	dsdc_annotation_t  annotation;
};

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

namespace RPC {

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
		DSDC_GET (dsdc_get_arg_t) = 3;

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
         * get with expiry times
         */
		dsdc_get_res_t
		DSDC_GET2 (dsdc_req_t) = 12;

        /*
         * multi-get with expiry times
         */
		dsdc_mget_res_t
		DSDC_MGET2 (dsdc_mget2_arg_t) = 13;

	/*
	 * Newest interface: with JY's expiration times, and
	 * also support for statistics.
	 */
	 dsdc_get_res_t
	 DSDC_GET3 (dsdc_get3_arg_t) = 14;

	 dsdc_mget_res_t
	 DSDC_MGET3 (dsdc_mget3_arg_t) = 15;

	 dsdc_res_t 
	 DSDC_PUT3 (dsdc_put3_arg_t) = 16;

	 dsdc_slave_statistics_t
	 DSDC_GET_STATS(dsdc_get_stats_arg_t) = 17;

	 dsdc_get_stats_single_res_t
	 DSDC_GET_STATS_SINGLE(dsdc_get_stats_single_arg_t) = 18;
	  
	 dsdc_res_t
	 DSDC_REMOVE3 (dsdc_remove3_arg_t) = 19;

	 void
	 DSDC_SET_STATS_MODE(bool) = 20;

	 dsdc_res_t
	 DSDC_PUT4(dsdc_put4_arg_t) = 21;

	  

#ifndef DSDC_NO_CUPID
/*
 *-----------------------------------------------------------------------
 * Below are custom RPCs for matching and okcupid-related functions
 * in particular (with procno >= 100...)
 *
 */
		match_frontd_match_results_t
                DSDC_COMPUTE_MATCHES(matchd_frontd_dcdc_arg_t) = 100;
#endif

	} = 1;
} = 30002;

};

/*
 * Some XDR sturctures for writing/reading files in FS cache.
 */

%#define SHA1SZ 20

typedef opaque checksum_t[SHA1SZ];

struct fscache_file_data_t {
	unsigned timestamp;
	opaque data<>;
};

struct fscache_file_t {
	checksum_t checksum;
	fscache_file_data_t data;
};
