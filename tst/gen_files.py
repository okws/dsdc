import os
import sys
import random

def usage ():
    print "usage: %s <iters>" % sys.argv[0]
    sys.exit (1)

class Gen:

    def __init__ (self):
        pass
    
    def create (self):
        fn = self.rand_i ()
        print "c %d %d" % ( fn, self.rand_i ())

    def rand_i (self):
        return (random.randint (0, 2**32 - 1))

    def run (self, n):
        for i in range (n):
            self.create ()

try:
    iter = int (sys.argv[1])
except IndexError:
    usage ();
except ValueError:
    usage ()

g = Gen ()
g.run (iter)
