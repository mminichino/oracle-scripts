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
             -r Response template  (overrides -v; default: \$SCRIPTDIR/db_inst_\$version.rsp)"

unset RSP_TEMPLATE
VERSION=193
INSTALL_DIR=/tmp
INSTALL_RSP=db_inst.rsp

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

function version_major {
   case "$VERSION" in
      112|11.2|11)  echo 11 ;;
      121|12.1)     echo 12 ;;
      122|12.2)     echo 12 ;;
      183|18)       echo 18 ;;
      193|19)       echo 19 ;;
      *)            err_exit "Unsupported version '$VERSION'" ;;
   esac
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

MAJOR=$(version_major)
if [ "$MAJOR" -ge 18 ]; then
   RUNINSTALLER="$ORACLE_HOME/runInstaller"
   IGNORE_OPTS="-ignorePrereqFailure"
else
   RUNINSTALLER="$ORACLE_HOME/database/runInstaller"
   IGNORE_OPTS="-ignoresysprereqs -ignoreprereq"
fi
[ ! -x "$RUNINSTALLER" ] && err_exit "runInstaller not found or not executable: $RUNINSTALLER"

if [ -f "$INSTALL_DIR/$INSTALL_RSP" ]; then
   info_msg "$INSTALL_DIR/$INSTALL_RSP exists"
   echo -n "Remove? (y/n): "
   read ANSWER
   if [ "$ANSWER" = "y" ]; then
      rm -f "$INSTALL_DIR/$INSTALL_RSP"
   else
      echo "Aborting ..."
      exit 1
   fi
fi

cp "$RSP_TEMPLATE" "$INSTALL_DIR/$INSTALL_RSP" || err_exit "Failed to copy response template"
sed -i -e "s|###ORACLE_BASE###|$ORACLE_BASE|g" "$INSTALL_DIR/$INSTALL_RSP"
sed -i -e "s|###ORACLE_HOME###|$ORACLE_HOME|g" "$INSTALL_DIR/$INSTALL_RSP"

UNRESOLVED=$(grep -oE '###[A-Z0-9_]+###' "$INSTALL_DIR/$INSTALL_RSP" | sort -u | tr '\n' ' ')
if [ -n "$UNRESOLVED" ]; then
   err_exit "Unresolved placeholders in $INSTALL_DIR/$INSTALL_RSP: $UNRESOLVED"
fi

ORA_INVENTORY="$ORACLE_BASE/oraInventory"

# INS-32035: inventory must be empty and writable. A prior failed install often
# leaves root-owned files that the oracle user cannot remove or even list.
prepare_inventory() {
   if [ -f /etc/oraInst.loc ]; then
      err_exit "Inventory already registered via /etc/oraInst.loc; clear it manually for a re-install"
   fi
   if [ -e "$ORA_INVENTORY" ]; then
      info_msg "Removing unregistered inventory at $ORA_INVENTORY"
      sudo rm -rf "$ORA_INVENTORY" || err_exit "Failed to remove $ORA_INVENTORY (try: sudo rm -rf $ORA_INVENTORY)"
   fi
   # Stale OUI session dirs can also trigger INS-32035
   sudo rm -rf /tmp/OraInstall* /tmp/CVU* 2>/dev/null || true

   mkdir -p "$ORA_INVENTORY" || err_exit "Cannot create $ORA_INVENTORY"
   if [ -n "$(ls -A "$ORA_INVENTORY" 2>/dev/null)" ]; then
      err_exit "Inventory $ORA_INVENTORY is not empty after cleanup"
   fi
   [ -w "$ORA_INVENTORY" ] || err_exit "Inventory $ORA_INVENTORY is not writable by $(id -un)"
}

prepare_inventory

echo "Oracle Base    : $ORACLE_BASE"
echo "Oracle Home    : $ORACLE_HOME"
echo "Inventory      : $ORA_INVENTORY"
echo "DB Version     : $VERSION (major $MAJOR)"
echo "runInstaller   : $RUNINSTALLER"
echo "Rsp Template   : $RSP_TEMPLATE"
echo "Install Rsp    : $INSTALL_DIR/$INSTALL_RSP"
echo ""

info_msg "Starting silent software install"
"$RUNINSTALLER" -silent -force -waitforcompletion \
   -responsefile "$INSTALL_DIR/$INSTALL_RSP" \
   $IGNORE_OPTS \
   || err_exit "runInstaller failed"

info_msg "Running orainstRoot.sh"
sudo "$ORACLE_BASE/oraInventory/orainstRoot.sh" || err_exit "orainstRoot.sh failed"

info_msg "Running root.sh"
sudo "$ORACLE_HOME/root.sh" || err_exit "root.sh failed"

rm -f "$INSTALL_DIR/$INSTALL_RSP"
info_msg "Oracle software install complete"
exit 0
