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
  DSDC_DATA_DISAPPEARED = 14,   /* as above, but data disappeared */
  DSDC_TOO_BIG = 15,            /* packet was too big; don't send */
  DSDC_EXPIRED = 16             /* current entry is still in dsdc, but expired */
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

enum dsdc_slave_type_t {
    DSDC_NORMAL_SLAVE = 0,
    DSDC_REDIS_SLAVE = 1
};

struct dsdcx_slave_t {
 	dsdc_keyset_t keys;
	string hostname<>;
	int port;
};

struct dsdcx_slave2_t {
    dsdc_keyset_t keys;
	string hostname<>;
	int port;
    dsdc_slave_type_t slave_type;
};

struct dsdcx_state_t {
	dsdcx_slave_t slaves<>;
	dsdcx_slave_t *lock_server;
};

struct dsdcx_state2_t {
    dsdcx_slave2_t slaves<>;
    dsdcx_slave_t* lock_server;
};

struct dsdc_register_arg_t {
 	dsdcx_slave_t slave;
	bool primary;
	bool lock_server;
};

struct dsdc_register2_arg_t {
    dsdcx_slave2_t slave;
    bool primary;
    bool lock_server;
};

union dsdc_getstate_res_t switch (bool needupdate) {
case true:
	dsdcx_state_t state;
case false:
	void;
};

union dsdc_getstate2_res_t switch (bool needupdate) {
case true:
	dsdcx_state2_t state;
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

/* ------------------------------------------------------------- */
/* aiod2 data */

typedef string aiod_file_t<>;
typedef aiod_file_t aiod_files_t<>;

struct aiod_str_to_file_arg_t {
    aiod_file_t file;
    opaque data<>;
    int flags;
    int mode;
    bool sync;
    bool canfail;
    bool atomic;                   /* make a temp, then move atomically.. */
};

union aiod_file_to_str_res_t switch (int code) {
case 0:
     opaque data<>;
default:
     void;
};

struct aiod_mkdir_arg_t {
    aiod_file_t file;
    int mode;
};

union aiod_glob_res_t switch (int code) {
case 0:
     aiod_files_t files;
default:
     void;
};

struct aiod_glob_arg_t {
     aiod_file_t dir;
     aiod_file_t pattern;
};

struct aiod_statvfs_t {
    unsigned hyper aiod_f_bsize;    /* file system block size */
    unsigned hyper aiod_f_frsize;   /* fragment size */
    unsigned hyper aiod_f_blocks;   /* size of fs in f_frsize units */
    unsigned hyper aiod_f_bfree;    /* # free blocks */
    unsigned hyper aiod_f_bavail;   /* # free blocks for non-root */
    unsigned hyper aiod_f_files;    /* # inodes */
    unsigned hyper aiod_f_ffree;    /* # free inodes */
    unsigned hyper aiod_f_favail;   /* # free inodes for non-root */
    unsigned hyper aiod_f_fsid;     /* file system ID */
    unsigned hyper aiod_f_flag;     /* mount flags */
    unsigned hyper aiod_f_namemax;  /* maximum filename length */
};

struct aiod_stat_t {
    unsigned hyper aiod_st_dev;     /* ID of device containing file */
    unsigned hyper aiod_st_ino;     /* inode number */
    unsigned hyper aiod_st_mode;    /* protection */
    unsigned hyper aiod_st_nlink;   /* number of hard links */
    unsigned hyper aiod_st_uid;     /* user ID of owner */
    unsigned hyper aiod_st_gid;     /* group ID of owner */
    unsigned hyper aiod_st_rdev;    /* device ID (if special file) */
    unsigned hyper aiod_st_size;    /* total size, in bytes */
    unsigned hyper aiod_st_blksize; /* blocksize for file system I/O */
    unsigned hyper aiod_st_blocks;  /* number of 512B blocks allocated */
    unsigned hyper aiod_st_atime;   /* time of last access */
    unsigned hyper aiod_st_mtime;   /* time of last modification */
    unsigned hyper aiod_st_ctime;   /* time of last status change */
};

union aiod_stat_res_t switch (int code) {
case 0:
    aiod_stat_t stat;
default:
    void;
};

union aiod_statvfs_res_t switch (int code) {
case 0:
    aiod_statvfs_t stat;
default:
    void;
};

/* ------------------------------------------------------------- */


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

     dsdc_res_t	
     DSDC_REGISTER2 (dsdc_register2_arg_t) = 22;

     dsdc_getstate2_res_t	
     DSDC_GETSTATE2 (dsdc_key_t) = 23;

	} = 1;
} = 30002;


program AIOD_PROG {

	version AIOD_VERS {

		void
		AIOD2_NULL(void) = 0;

		int
		AIOD2_STR_TO_FILE(aiod_str_to_file_arg_t) = 1;		

		aiod_file_to_str_res_t
		AIOD2_FILE_TO_STR(aiod_file_t) = 2;

		int
		AIOD2_REMOVE(aiod_file_t) = 3;

		int
		AIOD2_MKDIR(aiod_mkdir_arg_t) = 4;

		aiod_statvfs_res_t
		AIOD2_STATVFS(aiod_file_t) = 5;

		aiod_stat_res_t
		AIOD2_STAT(aiod_file_t) = 6;

		aiod_glob_res_t
		AIOD2_GLOB(aiod_glob_arg_t) = 7;
	} = 2;

} = 30003;

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

