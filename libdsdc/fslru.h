

// -*-c++-*-

#include "fscache.h"
#include "dsdc_prot.h"
#include "crypt.h"
#include "arpc.h"
#include "sha1.h"

namespace fscache {

  void report_cb (str fn, int res);
  

  enum { DAY = 24 * 60 * 60 } ;

  template<class K, class V, class F = file_id_maker_t<K> >
  class lru {
  public:
    
    lru (const str &n, engine_t *e,
	 u_int timeout = DAY, size_t sz = 0x1000) 
      : _name (n),
	_iface (e),
	_timeout (timeout),
	_max_size (sz) {}

    void insert (const K &key, ptr<V> value) 
    {
      remove_from_mem (key);
      write_out (key, *value);
      entry *e = New entry (key, value);
      insert_into_mem (e);
      clean ();
    }

    void insert (const K &key, const V &value) 
    {
      ptr<V> v = New refcounted<V> (value);
      insert (key, v);
    }

    void remove (const K &key, cbi cb)
    {
      entry *e = _tab[key];
      if (e) {
	remove_from_mem (e);
	_iface.remove (_file_id_maker (key), cb);
      } else {
	(*cb) (-ENOENT);
      }
    }

    TAMED void 
    get (K key, callback<void, ptr<V> > cb)
    {
      VARS {
	ptr<V> v;
	entry *e;
	int rc;
	time_t tm;
      }
      e = _tab[key];
      if (e) {
	touch_in_memory (e);
      } else {
	BLOCK { _iface.load (_file_id_maker (key), @(rc, tm, v)); }
	if (rc == 0) {
	  e = New entry (key, v);
	  insert_into_mem (e);
	  clean ();
	}
      }
      SIGNAL (cb, v);
    }

  protected:

    void remove_from_mem (const K &key)
    {
      entry *e = _tab[key];
      if (e)
	remove_from_mem (e);
    }
	      
    void insert_into_mem (entry *e)
    {
      _q.insert_tail (e);
      _tab.insert (e);
    }

    void remove_from_mem (entry *e)
    {
      _q.remove (e);
      _tab.remove (e);
      delete e;
    }
    
    void write_out (const K &key, const V &val)
    {
      file_id_t id = _file_id_maker (key);
      _iface.store (id, _timeout, val, wrap (report_cb, _iface.filename (id)));
    }


  protected:
    const str _name;
    iface_t<V> _iface;
    u_int _timeout;
    size_t _max_siz;
    const F _file_id_maker;

    tailq<entry, &entry::_qlnk> _q;
    ihash<K, entry, &entry::_key, &entry::_hlnk> _tab;
    
  };

};
