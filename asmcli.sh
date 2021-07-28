#!/bin/sh
#
SCRIPTDIR=$(cd $(dirname $0) && pwd)
source $SCRIPTDIR/lib/libcommon.sh
PRINT_USAGE="Usage: $0 command [ args ]"

asm_cli $@

