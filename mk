#!/bin/sh

for d in libdsdc dsdc
do
	(cd $d && ~/bin/indentmk.sh *.C *.h *.T)
done
