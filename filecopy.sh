#!/bin/sh
#
SCRIPTDIR=$(cd $(dirname $0) && pwd)
source $SCRIPTDIR/lib/libcommon.sh
PRINT_USAGE="Usage: $0 src dest"

db_copy $1 $2

