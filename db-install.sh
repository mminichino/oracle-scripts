#!/bin/bash
#
# Silent Oracle Database software install using db_inst*.rsp templates.
#
SCRIPTDIR=$(cd $(dirname $0) && pwd)
source $SCRIPTDIR/lib/libcommon.sh
PRINT_USAGE="Usage: $0 [-b oracle_base] [-o oracle_home] [-v version] [-r rsp_template]
             -b Oracle Base        (or ORACLE_BASE env)
             -o Oracle Home        (or ORACLE_HOME env)
             -v Version for rsp    112|121|122|183|193 (default: 193)
             -r Response template  (overrides -v; default: \$SCRIPTDIR/db_inst_\$version.rsp)

runInstaller must be in PATH or at \$ORACLE_HOME/runInstaller."

unset RSP_TEMPLATE
VERSION=193
INSTALL_RSP=/tmp/db_inst.rsp

function select_rsp_template {
   case "$VERSION" in
      112|11.2|11)
         echo "$SCRIPTDIR/db_inst.rsp"
         ;;
      121|12.1)
         echo "$SCRIPTDIR/db_inst_121.rsp"
         ;;
      122|12.2)
         echo "$SCRIPTDIR/db_inst_122.rsp"
         ;;
      183|18)
         echo "$SCRIPTDIR/db_inst_183.rsp"
         ;;
      193|19)
         echo "$SCRIPTDIR/db_inst_193.rsp"
         ;;
      *)
         err_exit "Unsupported version '$VERSION' (use 112, 121, 122, 183, or 193)"
         ;;
   esac
}

function find_runinstaller {
   if which runInstaller >/dev/null 2>&1; then
      which runInstaller
   elif [ -x "$ORACLE_HOME/runInstaller" ]; then
      echo "$ORACLE_HOME/runInstaller"
   else
      err_exit "runInstaller not found in PATH or \$ORACLE_HOME"
   fi
}

while getopts "b:o:v:r:" opt
do
  case $opt in
    b)
      ORACLE_BASE=$OPTARG
      ;;
    o)
      ORACLE_HOME=$OPTARG
      ;;
    v)
      VERSION=$OPTARG
      ;;
    r)
      RSP_TEMPLATE=$OPTARG
      ;;
    \?)
      print_usage
      exit 1
      ;;
  esac
done

[ -z "$ORACLE_BASE" ] && err_exit "ORACLE_BASE not set (use -b or export ORACLE_BASE)"
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME not set (use -o or export ORACLE_HOME)"

export ORACLE_BASE ORACLE_HOME

[ -z "$RSP_TEMPLATE" ] && RSP_TEMPLATE=$(select_rsp_template)
[ ! -f "$RSP_TEMPLATE" ] && err_exit "Response file template not found: $RSP_TEMPLATE"

RUNINSTALLER=$(find_runinstaller)

if [ -f "$INSTALL_RSP" ]; then
   info_msg "$INSTALL_RSP exists"
   echo -n "Remove? (y/n): "
   read ANSWER
   if [ "$ANSWER" = "y" ]; then
      rm -f "$INSTALL_RSP"
   else
      echo "Aborting ..."
      exit 1
   fi
fi

cp "$RSP_TEMPLATE" "$INSTALL_RSP" || err_exit "Failed to copy response template"
sed -i -e "s|###ORACLE_BASE###|$ORACLE_BASE|g" "$INSTALL_RSP"
sed -i -e "s|###ORACLE_HOME###|$ORACLE_HOME|g" "$INSTALL_RSP"

if grep -q '###' "$INSTALL_RSP"; then
   err_exit "Unresolved placeholders remain in $INSTALL_RSP"
fi

echo "Oracle Base    : $ORACLE_BASE"
echo "Oracle Home    : $ORACLE_HOME"
echo "runInstaller   : $RUNINSTALLER"
echo "Rsp Template   : $RSP_TEMPLATE"
echo "Install Rsp    : $INSTALL_RSP"
echo ""

info_msg "Starting silent software install"
"$RUNINSTALLER" -silent -force -waitforcompletion \
   -responsefile "$INSTALL_RSP" \
   -ignoresysprereqs -ignoreprereq \
   || err_exit "runInstaller failed"

info_msg "Running orainstRoot.sh"
sudo "$ORACLE_BASE/oraInventory/orainstRoot.sh" || err_exit "orainstRoot.sh failed"

info_msg "Running root.sh"
sudo "$ORACLE_HOME/root.sh" || err_exit "root.sh failed"

rm -f "$INSTALL_RSP"
info_msg "Oracle software install complete"
exit 0
