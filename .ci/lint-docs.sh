#!/bin/sh

od=`pwd`
cd docs
./node_modules/markdownlint-cli/markdownlint.js .
ec=$?
cd $od

exit $ec
