import os
import sys
import random

def usage ():
    print "usage: %s <iters>" % sys.argv[0]
    sys.exit (1)

class Gen:

    def __init__ (self):
        self.files = []
        self.deletes = set ()
    
    CREATE = 0
    LOAD = 1
    DELETE = 2

    def rand_op (self):
        r = random.random ()
        if r < .8:
            op = self.CREATE
        elif r < .95:
            op = self.LOAD
        else:
            op = self.DELETE
        return op
        
    def create (self):
        fn = self.rand_i ()
        print "c %d %d" % ( fn, self.rand_i ())
        self.files += [ fn ]

    def load (self):
        go = True
        while go:
            c = random.choice (self.files)
            go = c in self.deletes
        print "l %d" % c

    def delete (self):
        go = True
        while go:
            c = random.choice (self.files)
            go = c in self.deletes
        self.deletes.add (c)
        print "d %d" % c

    def rand_i (self):
        return (random.randint (0, 2**32 - 1))

    def run (self, n):
        for i in range (n):
            op = self.rand_op ()
            if len (self.files) < 100 or op == self.CREATE:
                self.create ()
            elif op == self.LOAD:
                self.load ()
            else:
                self.delete ()

try:
    iter = int (sys.argv[1])
except IndexError:
    usage ();
except ValueError:
    usage ()

g = Gen ()
g.run (iter)
