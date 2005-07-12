
typedef unsigned  tst_key_t;

struct tst_obj_t {
	tst_key_t key;
	string val<>;
};

struct tst_obj_checked_t {
	tst_obj_t obj;
	opaque checksum[20];	
};
