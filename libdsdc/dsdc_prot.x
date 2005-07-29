
%#define DSDC_KEYSIZE 20
%#define DSDC_DEFAULT_PORT 30002

typedef opaque dsdc_key_t[DSDC_KEYSIZE];

typedef dsdc_key_t dsdc_keyset_t<>;

typedef opaque dsdc_custom_t<>;

struct dsdc_key_template_t {
	unsigned id;
	unsigned pid;
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
	DSDC_DEAD = 7
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

struct dsdcx_slave_t {
 	dsdc_keyset_t keys;
	string hostname<>;
	int port;
};

struct dsdcx_slaves_t {
	dsdcx_slave_t slaves<>;
};

struct dsdc_register_arg_t {
 	dsdcx_slave_t slave;
	bool primary;
};

union dsdc_getstate_res_t switch (bool needupdate) {
case true:
	dsdcx_slaves_t slaves;
case false:
	void;
};

program DSDC_PROG 
{
	version DSDC_VERS {
	
		void
		DSDC_NULL (void) = 0;

/*
 * these are the only 3 calls that clients should use.  they should
 * issue them to the master nodes, who will deal with them:
 *
 *  INSERT / REMOVE / LOOKUP
 * 
 */
		dsdc_res_t
		DSDC_PUT (dsdc_put_arg_t) = 1;

		dsdc_res_t
		DSDC_REMOVE (dsdc_key_t) = 2;
		
		dsdc_get_res_t
		DSDC_GET (dsdc_key_t) = 3;

/*
 *  for extending DSDC for custom purposes (like doing computations 
 *  and batch queries on the slaves).
 */
                dsdc_custom_t
                DSDC_CUSTOM(dsdc_custom_t) = 4;

/*
 * the following two calls are for internal management, that dsdc
 * uses for itself:
 *
 *   REGISTER / HEARTBEAT
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
		DSDC_REGISTER (dsdc_register_arg_t) = 10;

		/*
 		 * heartbeat;  a slave must send a periodic heartbeat
	  	 * message, otherwise, the master will think it's dead.
		 */
		void
		DSDC_HEARTBEAT (void) = 11;

		/*
		 * when a new node is inserted, the master broadcasts
		 * all of the other nodes, alerting them to clean out
		 * their caches.  this is also when we would add
		 * data movement protocols.
		 */
		dsdc_res_t
		DSDC_NEWNODE (dsdcx_slave_t) = 12;

		/*
		 * nodes should periodically get the complete system
		 * state and clean out their caches accordingly.
		 */
		dsdc_getstate_res_t	
		DSDC_GETSTATE (dsdc_key_t) = 13;

	} = 1;
} = 30002;
