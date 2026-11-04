#!/bin/bash
#
#
unset SID_ARG
unset PDB_ARG
# DATADIR, RECODIR, ORACLE_SID, ORACLE_PDB, ORACLE_HOME, ORACLE_DATA_DIR,
# and ORACLE_CHARACTERSET are taken from the environment when set.
# Command-line flags override those values.
CREATE_PDB=0
SET_PASSWORD=0
ORACLE_CHARACTERSET="${ORACLE_CHARACTERSET:-US7ASCII}"
DB_TOTAL_MEMORY_MB=2048
SCRIPTDIR=$(cd $(dirname $0) && pwd)
DBCARSPFILE="dbca-si.rsp"
LISTENER_ONLY=0
ENABLELOG_ONLY=0
PWDFILE_ONLY=0
ASM_MODE=0
FRA_LOG_MODE=0

function print_usage {
   echo "Usage: $0 [-s SID] [-p pdb_name] [-d data_dir] [-r reco_dir] [-c] [-a] [-l] [-g] [-w] [-m] [-f]"
   echo "          -s Oracle SID (env ORACLE_SID, else oradb)"
   echo "          -p PDB name (env ORACLE_PDB, else pdb_<SID>)"
   echo "          -c Create a CDB with PDB (defaults to Non-CDB)"
   echo "          -a Ask for sys/system password (defaults to a generated password)"
   echo "          -d Data directory root (env ORACLE_DATA_DIR or DATADIR; must exist)"
   echo "          -r Recovery directory (env RECODIR, else data_dir/fra)"
   echo "          -l Setup listener and exit"
   echo "          -g Enable archivelog and exit"
   echo "          -w Create Oracle password file and exit"
   echo "          -m Enable ASM mode (provide disk group with -d option)"
   echo "          -f Use FRA for archive logs"
   echo "Requires ORACLE_HOME. Run from an oracle login shell (su - oracle)."
}

function err_exit {
   if [ -n "$1" ]; then
      echo "[!] Error: $1"
   else
      print_usage
   fi
   exit 1
}

function warn_msg {
   if [ -n "$1" ]; then
      echo "[i] Warning: $1"
   fi
}

function info_msg {
   if [ -n "$1" ]; then
      echo "[i] Notice: $1"
   fi
}

function password_ok {
   local p="$1"
   [ "${#p}" -ge 8 ] || return 1
   printf '%s' "$p" | grep -q '[A-Z]' || return 1
   printf '%s' "$p" | grep -q '[a-z]' || return 1
   printf '%s' "$p" | grep -q '[0-9]' || return 1
   if [ -n "$ORACLE_SID" ]; then
      printf '%s' "$p" | grep -qi "$ORACLE_SID" && return 1
   fi
   return 0
}

function get_password {
   while true
   do
      echo -n "Password: "
      read -s PASSWORD
      echo ""
      echo -n "Retype Password: "
      read -s CHECK_PASSWORD
      echo ""
      if [ "$PASSWORD" != "$CHECK_PASSWORD" ]; then
         echo "Passwords do not match"
      elif ! password_ok "$PASSWORD"; then
         echo "Password must be at least 8 characters and include uppercase, lowercase, and a digit, and must not contain the SID."
      else
         break
      fi
   done
   export ORACLE_PWD=$PASSWORD
}

function generate_password {
   local p tries=0
   command -v openssl >/dev/null 2>&1 || err_exit "openssl not found; cannot generate a password (use -a)"
   while [ "$tries" -lt 20 ]
   do
      tries=$((tries + 1))
      # Aa1 forces the 19c complexity classes; the random part supplies length.
      p="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 12)Aa1"
      password_ok "$p" && break
      p=""
   done
   [ -n "$p" ] || err_exit "Failed to generate a password that meets 19c complexity rules"
   export ORACLE_PWD=$p
}

function check_oracle_env {
   if [ "$(id -u)" -eq 0 ]; then
      err_exit "Run as the oracle user, not root (su - oracle)."
   fi
   [ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not set. Log in as oracle (su - oracle) or export ORACLE_HOME."
   [ ! -d "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not a directory: $ORACLE_HOME"
   case ":$PATH:" in
      *":$ORACLE_HOME/bin:"*) ;;
      *)
         export PATH="$ORACLE_HOME/bin:$PATH"
         info_msg "Added $ORACLE_HOME/bin to PATH"
         ;;
   esac
   if [ -z "$LD_LIBRARY_PATH" ]; then
      export LD_LIBRARY_PATH="$ORACLE_HOME/lib"
   fi
   command -v sqlplus >/dev/null 2>&1 || err_exit "sqlplus not found. Check ORACLE_HOME ($ORACLE_HOME)."
}

function resolve_hostname {
   [ -n "$HOST_FQDN" ] && return 0
   local h ip
   h=$(hostname -f 2>/dev/null || true)
   if [ -z "$h" ]; then
      h=$(hostname 2>/dev/null || true)
      [ -n "$h" ] && warn_msg "hostname -f returned nothing; using '$h'. Add this host to DNS or /etc/hosts."
   fi
   [ -z "$h" ] && err_exit "Cannot resolve a hostname. Add '<ip> <hostname>' to /etc/hosts."
   ip=$(getent hosts "$h" 2>/dev/null | awk '{print $1; exit}')
   if [ -z "$ip" ]; then
      warn_msg "Hostname '$h' does not resolve. Add '<ip> $h' to /etc/hosts or the listener may fail to start."
   elif [ "${ip#127.}" != "$ip" ]; then
      warn_msg "Hostname '$h' resolves to loopback ($ip). Map it to a non-loopback address in /etc/hosts."
   fi
   HOST_FQDN=$h
}

function check_memory {
   local kb mb
   kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
   if [ -z "$kb" ]; then
      warn_msg "Cannot read /proc/meminfo; skipping memory check."
      return 0
   fi
   mb=$((kb / 1024))
   if [ "$mb" -lt "$DB_TOTAL_MEMORY_MB" ]; then
      err_exit "Host has ${mb} MB RAM; the dbca response sets totalMemory=${DB_TOTAL_MEMORY_MB}. Need at least ${DB_TOTAL_MEMORY_MB} MB."
   fi
   if [ "$mb" -lt $((DB_TOTAL_MEMORY_MB + 1024)) ]; then
      warn_msg "Host has ${mb} MB RAM and the database is configured for ${DB_TOTAL_MEMORY_MB} MB. The OS may be memory-starved."
   fi
}

function create_password_file {
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME not set."
[ -z "$ORACLE_SID" ] && err_exit "ORACLE_SID not set."
which orapwd >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "orapwd not found."
if [ -f $ORACLE_HOME/dbs/orapw${ORACLE_SID} ]; then
   info_msg "Password file already exists."
   return
fi

get_password

orapwd file=$ORACLE_HOME/dbs/orapw${ORACLE_SID} password=${ORACLE_PWD} entries=30
}

function listener_register {
[ -z "$ORACLE_SID" ] && err_exit "ORACLE_SID not set."

if [ -z "$(ps -ef |grep ora_pmon_$ORACLE_SID | grep -v grep | awk '{print $NF}')" ]; then
   info_msg "Register listener: Instance $ORACLE_SID not running"
   return
fi

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

echo -n "Dynamically registering SID $ORACLE_SID ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter system set local_listener = '' ;
   alter system register ;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to register instance"
else
   echo "Done."
fi
}

function listener_config {

LSNR_RUNNING=0
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not set"

which lsnrctl >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "lsnrctl not found"

lsnrctl status >/dev/null 2>&1
if [ $? -eq 0 ]; then
   info_msg "Listener running"
   LSNR_RUNNING=1
fi

resolve_hostname
LOCAL_HOSTNAME=$HOST_FQDN

if [ -n "$1" ]; then

echo "Configuring instance $1 on node $LOCAL_HOSTNAME"

grep -i $1 $ORACLE_HOME/network/admin/tnsnames.ora 2>&1 >/dev/null
[ $? -eq 0 ] && info_msg "Instance $1 already configured" && return

cat <<EOF >> $ORACLE_HOME/network/admin/tnsnames.ora
${1^^} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $LOCAL_HOSTNAME)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $1)
    )
  )

LISTENER_${1^^} =
  (ADDRESS = (PROTOCOL = TCP)(HOST = $LOCAL_HOSTNAME)(PORT = 1521))

EOF

[ $LSNR_RUNNING -eq 1 ] && lsnrctl reload

return

fi

[ $LSNR_RUNNING -eq 1 ] && return

echo "Configuring listener on node $(uname -n)"

mkdir -p $ORACLE_HOME/network/admin
echo "NAME.DIRECTORY_PATH= (TNSNAMES, EZCONNECT, HOSTNAME)" > $ORACLE_HOME/network/admin/sqlnet.ora

cat <<EOF > $ORACLE_HOME/network/admin/listener.ora
LISTENER =
(DESCRIPTION_LIST =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1))
    (ADDRESS = (PROTOCOL = TCP)(HOST = $LOCAL_HOSTNAME)(PORT = 1521))
  )
)

DEDICATED_THROUGH_BROKER_LISTENER=ON
DIAG_ADR_ENABLED = off
EOF

lsnrctl start || err_exit "Failed to start the listener"

}

function enable_archlog {

[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not set"
[ -z "$ORACLE_SID" ] && err_exit "ORACLE_SID is not set"
[ -z "$LOGDIR" ] && err_exit "Log directory is not set"

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

if [ "$FRA_LOG_MODE" -eq 0 ]; then
echo -n "Setting archive log destination to $LOGDIR ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   ALTER SYSTEM SET log_archive_dest_1='location=$LOGDIR' SCOPE=spfile;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to set log destination"
else
   echo "Done."
fi
fi

echo -n "Shutting down instance ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   shutdown immediate;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to shutdown instance $ORACLE_SID ..."
else
   echo "Done."
fi

echo -n "Starting instance mounted ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   startup mount;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to start instance $ORACLE_SID ..."
else
   echo "Done."
fi

echo -n "Setting archive log mode ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter database archivelog;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to set archive log mode for $ORACLE_SID ..."
else
   echo "Done."
fi

echo -n "Opening database ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter database open;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to open $ORACLE_SID ..."
else
   echo "Done."
fi

}

function add_local_listener {
[ -z "$ORACLE_SID" ] && err_exit "ORACLE_SID not set."
resolve_hostname
LOCAL_HOSTNAME=$HOST_FQDN

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

echo -n "Set local_listener ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter system set local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=$LOCAL_HOSTNAME)(PORT=1521))';
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to set local_listener"
else
   echo "Done."
fi

}

function get_version {

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

oracleVersionMaj=$(sqlplus -V | grep -i version | sed -e 's/^.* \([0-9]*\)\..*$/\1/')
oracleVersionMin=$(sqlplus -V | grep -i version | sed -e 's/^.* [0-9]*\.\([0-9]*\).*$/\1/')

[ -z "$oracleVersionMaj" -o -z "$oracleVersionMin" ] && err_exit "Can not determine software version"

}

function fs_prep {
[ -z "$DATADIR" ] && err_exit "Data directory is required (use -d or export ORACLE_DATA_DIR)"

[ ! -d "$DATADIR" ] || [ ! -w "$DATADIR" ] && err_exit "Data directory is not accessible: $DATADIR"

LOGDIR=$DATADIR/log

if [ ! -d $LOGDIR ]; then
   mkdir $LOGDIR || err_exit "Can not create log directory"
else
   warn_msg "Log directory $LOGDIR exists"
fi

if [ -n "$RECODIR" ]; then
   if [ ! -d "$RECODIR" ] || [ ! -w "$RECODIR" ]; then
      err_exit "Recovery directory is not accessible: $RECODIR"
   fi
fi

if [ -z "$RECODIR" -a ! -d $DATADIR/fra ]; then
   mkdir $DATADIR/fra || err_exit "Can not create recovery directory"
   RECODIR=$DATADIR/fra
elif [ -z "$RECODIR" -a -d $DATADIR/fra ]; then
   RECODIR=$DATADIR/fra
   warn_msg "Recovery directory $DATADIR/fra exists"
fi

if [ ! -d $DATADIR/dbf ]; then
   mkdir $DATADIR/dbf || err_exit "Can not create data file directory"
else
   warn_msg "Data file directory $DATADIR/dbf exists"
fi

DATAFILEDIR=$DATADIR/dbf
}

function asm_prep {
[ -z "$ORACLE_SID" ] && err_exit "Oracle SID is not set"
HOST_GRID_HOME=$(dirname $(dirname $(ps -ef |grep evmd.bin | grep -v grep | awk '{print $NF}')))
[ -z "$HOST_GRID_HOME" ] && err_exit "Oracle CRS does not seem to be running"
HOST_ASM_INSTANCE=$(ps -ef | grep pmon_+ASM | grep -v grep | awk '{print $NF}' | sed -e 's/^.*_pmon_//')
[ -z "$HOST_ASM_INSTANCE" ] && err_exit "ASM does not appear to be running"

ORACLE_HOME_SAVE=$ORACLE_HOME
PATH_SAVE=$PATH
ORACLE_SID_SAVE=$ORACLE_SID

export ORACLE_HOME=$HOST_GRID_HOME
export PATH=$ORACLE_HOME/bin:$PATH
export ORACLE_SID=$HOST_ASM_INSTANCE

asmcmd ls $DATADIR >/dev/null 2>&1
[ $? -ne 0 ] && err_exit "Disk group $DATADIR does not exist."

if [ -n "$RECODIR" ]; then
   asmcmd ls $RECODIR >/dev/null 2>&1
   [ $? -ne 0 ] && err_exit "Disk group $DATADIR does not exist."
   LOGDIR=$RECODIR
else
   RECODIR=$DATADIR
   LOGDIR=$DATADIR
fi

DATAFILEDIR=$DATADIR

export ORACLE_HOME=$ORACLE_HOME_SAVE
export PATH=$PATH_SAVE
export ORACLE_SID=$ORACLE_SID_SAVE
}

while getopts "s:p:cad:r:lgwmf" opt
do
  case $opt in
    s)
      SID_ARG=$OPTARG
      ;;
    p)
      PDB_ARG=$OPTARG
      ;;
    c)
      CREATE_PDB=1
      ;;
    a)
      SET_PASSWORD=1
      ;;
    d)
      DATADIR=$OPTARG
      ;;
    r)
      RECODIR=$OPTARG
      ;;
    l)
      LISTENER_ONLY=1
      ;;
    g)
      ENABLELOG_ONLY=1
      ;;
    w)
      PWDFILE_ONLY=1
      ;;
    m)
      ASM_MODE=1
      DBCARSPFILE="dbca-si-asm.rsp"
      ;;
    f)
      FRA_LOG_MODE=1
      ;;
    \?)
      print_usage
      exit 1
      ;;
  esac
done

if [ "$CREATE_PDB" -eq 1 ]; then
   if [ "$ASM_MODE" -eq 1 ]; then
      DBCARSPFILE="dbca-si-cdb-asm.rsp"
   else
      DBCARSPFILE="dbca-si-cdb.rsp"
   fi
fi

check_oracle_env

if [ -n "$SID_ARG" ]; then
   export ORACLE_SID=$SID_ARG
elif [ -z "$ORACLE_SID" ]; then
   export ORACLE_SID=oradb
fi

if [ -n "$PDB_ARG" ]; then
   export ORACLE_PDB=$PDB_ARG
elif [ -z "$ORACLE_PDB" ]; then
   export ORACLE_PDB=pdb_${ORACLE_SID}
fi

if [ -z "$DATADIR" ]; then
   DATADIR="${ORACLE_DATA_DIR:-}"
fi

get_version

if [ "$LISTENER_ONLY" -eq 1 ]; then
   listener_config
   [ -n "$SID_ARG" ] && listener_config $SID_ARG
   [ -n "$SID_ARG" ] && listener_register
   exit 0
fi

if [ "$PWDFILE_ONLY" -eq 1 ]; then
   create_password_file
   exit 0
fi

if [ "$ASM_MODE" -eq 0 ]; then
   fs_prep
else
   asm_prep
fi

if [ "$ENABLELOG_ONLY" -eq 1 ]; then
   [ -n "$SID_ARG" ] && export ORACLE_SID=${SID_ARG}
   enable_archlog
   exit 0
fi

check_memory

if [ "$SET_PASSWORD" -eq 0 ]; then
   generate_password
   echo "ORACLE PASSWORD FOR SYS AND SYSTEM: $ORACLE_PWD";
else
   get_password
fi

echo "Oracle SID     : $ORACLE_SID"
echo "DB Version     : ${oracleVersionMaj}.${oracleVersionMin}"
echo -n "Create PDB     : "
if [ "$CREATE_PDB" -eq 0 ]; then
   echo "No"
else
   echo "Yes"
   echo "PDB Name       : $ORACLE_PDB"
fi
echo "Character Set  : $ORACLE_CHARACTERSET"
echo "Data File Dir  : $DATADIR"
echo "Recovery Dir   : $RECODIR"
echo "Log Dir        : $LOGDIR"
echo ""

if [ -f /tmp/dbca.rsp  ]; then
   info_msg "/tmp/dbca.rsp exists"
   echo -n "Remove? (y/n): "
   read ANSWER

   if [ "$ANSWER" == "y" ]; then
      rm /tmp/dbca.rsp
   else
      echo "Aborting ..."
      exit 1
   fi
fi

[ ! -f $SCRIPTDIR/$oracleVersionMaj/$DBCARSPFILE ] && err_exit "Can not open response file template $SCRIPTDIR/$oracleVersionMaj/$DBCARSPFILE"

cp $SCRIPTDIR/$oracleVersionMaj/$DBCARSPFILE /tmp/dbca.rsp

if [ "$CREATE_PDB" -eq 0 ]; then
   sed -i -e "s|###ORACLE_SID###|$ORACLE_SID|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_PWD###|$ORACLE_PWD|g" /tmp/dbca.rsp
   sed -i -e "s|###DATADIR###|$DATAFILEDIR|g" /tmp/dbca.rsp
   sed -i -e "s|###RECODIR###|$RECODIR|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_CHARACTERSET###|$ORACLE_CHARACTERSET|g" /tmp/dbca.rsp
else
   sed -i -e "s|###ORACLE_SID###|$ORACLE_SID|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_PWD###|$ORACLE_PWD|g" /tmp/dbca.rsp
   sed -i -e "s|###DATADIR###|$DATAFILEDIR|g" /tmp/dbca.rsp
   sed -i -e "s|###RECODIR###|$RECODIR|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_PDB###|$ORACLE_PDB|g" /tmp/dbca.rsp
   sed -i -e "s|###ORACLE_CHARACTERSET###|$ORACLE_CHARACTERSET|g" /tmp/dbca.rsp
fi

command -v dbca >/dev/null 2>&1 || err_exit "dbca not found. Check ORACLE_HOME ($ORACLE_HOME)."

listener_config

dbca -silent -createDatabase -responseFile /tmp/dbca.rsp || err_exit "Database $ORACLE_SID create failed"

listener_config $ORACLE_SID

if [ "$CREATE_PDB" -eq 1 ]; then
echo -n "Set PDB $ORACLE_PDB to auto open ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   ALTER PLUGGABLE DATABASE $ORACLE_PDB SAVE STATE;
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to set PDB state"
else
   echo "Done."
fi
fi

enable_archlog

add_local_listener

rm /tmp/dbca.rsp
exit 0
