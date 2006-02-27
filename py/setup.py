#!/usr/bin/env python

"""\
===========================
Python/SFS XDR module: ex1
===========================

A small example XDR module to test pysfs
"""

import os
import sys

import sfs.setup.util
import sfs.setup.dist

from distutils.core import setup
from distutils.extension import Extension
import distutils.sysconfig

classifiers = """
Development Status :: 5 - Production/Stable
Environment :: Other Environment
License :: OSI Approved :: GNU General Public License (GPL)
Operating System :: MacOS :: MacOS X
Operating System :: OS Independent
Operating System :: POSIX
Operating System :: POSIX :: Linux
Operating System :: Unix
Programming Language :: C++
Programming Language :: Python
Topic :: Libraries
"""

xdr_dict = { 'src_dir' : 'dsdc/', }

metadata = {
    'distclass' : sfs.setup.dist.xdr_Distribution,
    'name' : 'dsdc',
    'version' : '0.1',
    'description' : 'DSDC - Dirt Simple Distributed Cache',
    'long_description' : __doc__,
    'classifiers' :  [ c for c in classifiers.split ('\n') if c ],
    'xdr_modules' :  [ ( 'dsdc.prot' , xdr_dict ) ],
    'py_modules' :   [ 'dsdc.__init__' ]
    }

setup (**metadata)

    
