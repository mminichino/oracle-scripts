#!/bin/sh
#
CONFIG_DIR=""
HOT_BACKUP_FLAG=0
SEPARATE_PLUG_DBF=0
LOCAL_ORACLE_SID=""
GLOBAL_SID=""
dbIsCdb=0

err_end () {
  echo "Error: $1"
  [ -n "$tempfile" -a -f "$tempfile" ] && {
     echo "Current configuration file contents:"
     cat $tempfile
     rm $tempfile
  }
  exit 1
}

while getopts "s:d:hp" opt
do
  case $opt in
    s)
      export ORACLE_SID=$OPTARG
      ;;
    d)
      CONFIG_DIR=$OPTARG
      ;;
    h)
      HOT_BACKUP_FLAG=1
      ;;
    p)
      SEPARATE_PLUG_DBF=1
      ;;
    \?)
      err_end "Usage: $0 [ -s ORACLE_SID | -d /config/dir | -h ]"
      ;;
  esac
done

if [ -z "$(cut -d: -f 1 /etc/oratab | grep $ORACLE_SID)" ]; then
   # Try to get grid home
   GRID_HOME=$(dirname $(dirname $(ps -ef | grep evmd.bin | grep -v grep | awk '{print $NF}')))
   if [ -n "$GRID_HOME" ]; then
      export START_PATH=$PATH
      export PATH=$GRID_HOME/bin:$START_PATH
      export LD_LIBRARY_PATH=$GRID_HOME/lib
      ORACLE_HOME=$(srvctl config database -db $ORACLE_SID | grep -i "^oracle home" | awk '{print $NF}')
      LOCAL_ORACLE_SID=$(basename $(ls $ORACLE_HOME/dbs/hc_${ORACLE_SID}*.dat) | sed -e 's/hc_//' -e 's/\.dat//')
      if [ -z "$LOCAL_ORACLE_SID" ]; then
         err_end "Can not configure local instance SID from Grid Home $GRID_HOME"
      fi
      echo "CRS found, configured instance $LOCAL_ORACLE_SID from Grid."
      export PATH=$ORACLE_HOME/bin:$GRID_HOME/bin:$START_PATH
      export LD_LIBRARY_PATH==$ORACLE_HOME/lib
      GLOBAL_SID=$ORACLE_SID
      export ORACLE_SID=$LOCAL_ORACLE_SID
   else
      err_end "DB Instance $ORACLE_SID not found in /etc/oratab."
   fi
else
   ORAENV_ASK=NO
   source oraenv
fi

if [ -n "$GLOBAL_SID" ]; then
   DBNAME=$GLOBAL_SID
else
   DBNAME=$ORACLE_SID
fi

# Make sure the environment is properly set
if [ -z "$ORACLE_SID" -o -z "$ORACLE_HOME" ]
then
   echo "Oracle environment not set. Please set ORACLE_SID and ORACLE_HOME environment variables."
   exit 1
fi

status=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select status from v\\$instance ;
   exit;
EOF`

# Make sure the database is open
if [ "$status" != "OPEN" ]; then
   err_end "Database $ORACLE_SID not open. Please start the DB to continue."
fi

tempfile=$(mktemp)

dbversion=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select version from v\\$instance ;
   exit;
EOF`

echo "DBVERSION=$dbversion" > $tempfile

dbMajorRev=$(echo $dbversion | sed -n -e 's/^\([0-9]*\)\..*$/\1/p')

# Get PDB status for DB 12 and higher

if [ "$dbMajorRev" -ge 12 ]; then

dbIsCdbText=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select cdb from v\\$database ;
   exit;
EOF`

if [ $? -ne 0 ]; then
   err_end "Can not determine CDB status."
fi

if [ "$dbIsCdbText" = "YES" ]; then
   dbIsCdb=1
fi

fi

# Get list of datafiles

if [ -z "$CONFIG_DIR" -o "$HOT_BACKUP_FLAG" -eq 1 ]; then

if [ "$dbIsCdb" -eq 0 -o "$SEPARATE_PLUG_DBF" -eq 0 ]; then

datafiles=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\\$datafile ;
   exit;
EOF`

else

datafiles=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\\$datafile where con_id = 1 ;
   exit;
EOF`

fi

else

datafiles=$(ls $CONFIG_DIR/data_* 2>/dev/null)

fi
ret=$?

# Write datafile config to file
if [ $ret -eq 0 ] && [ -n "$datafiles" ]; then
   filearray=($datafiles)
   filecount=${#filearray[@]}
   firstfilename=$(echo $datafiles | awk '{print $1}')
   datadirname=$(dirname $firstfilename)
   echo -n "DATAFILES=" >> $tempfile
   count=1
   for filename in $datafiles; do
       [ "$count" -eq 1 ] && firstdbf=$filename
       if [ $count -eq $filecount ]; then
          echo "${filename}"
       else
          echo -n "${filename},"
       fi
   count=$(($count + 1))
   done >> $tempfile
else
   err_end "can not get datafiles $datafiles"
fi

# Write datafile mount point
dbfmountpoint=$(cd $(dirname $firstdbf); df -h . | tail -n 1 | awk '{print $NF}')
echo "DATAFILEMOUNTPOINT=$dbfmountpoint" >> $tempfile

if [ "$dbIsCdb" -eq 1 ]; then

pdbConIds=`sqlplus -S / as sysdba <<EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select con_id from v\\$containers where con_id <> 1 ;
EOF`

pdbConIdArray=($pdbConIds)

pdbCount=1
for ((i=0; i<${#pdbConIdArray[@]}; i=i+1)); do

pdbName=`sqlplus -S / as sysdba <<EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select lower(name) from v\\$containers where con_id = ${pdbConIdArray[$i]} ;
EOF`

pdbDatafiles=`sqlplus -S / as sysdba <<EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\\$datafile where con_id = ${pdbConIdArray[$i]} ;
EOF`

pdbName=$(echo $pdbName | sed -e 's/\$//g')

if [ "$pdbCount" -eq 1  ]; then
   pdbNameString=$(echo "PDB_NAMES=$pdbName")
else
   pdbNameString=$(echo "$pdbNameString,$pdbName")
fi

pdbFileArray=($pdbDatafiles)
pdbFileCount=${#pdbFileArray[@]}
pdbFirstFilename=$(echo $pdbDatafiles | awk '{print $1}')
pdbDataDirName=$(dirname $pdbFirstFilename)
echo -n "DATAFILES_${pdbCount}=" >> $tempfile
count=1
for filename in $pdbDatafiles; do
    [ "$count" -eq 1 ] && firstdbf=$filename
    if [ $count -eq $pdbFileCount ]; then
       echo "${filename}"
    else
       echo -n "${filename},"
    fi
    count=$(($count + 1))
done >> $tempfile

pdbCount=$(($pdbCount + 1))
done

echo $pdbNameString >> $tempfile

fi

# Write SID to file
echo "ORIG_ORACLE_SID=$DBNAME" >> $tempfile

# Get DB log mode
logmode=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select log_mode from v\\$database;
   exit;
EOF`

# If DB is in log mode save config to file
if [ "$logmode" = "ARCHIVELOG" ]; then
archfiles=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select destination from v\\$archive_dest where destination is not null ;
   exit;
EOF`
ret=$?
   if [ $ret -ne 0 -o -z "$archfiles" ]; then
      err_end "can not get archive log destinations $archfiles"
   fi
   archarray=($archfiles)
   archcount=${#archarray[@]}
   echo -n "ARCHDIRS=" >> $tempfile
   count=1
   for dirname in $archfiles; do
       if [ $count -eq $archcount ]; then
          echo "${dirname}"
       else
          echo -n "${dirname},"
       fi
       if [ $count -eq 1 ]; then
          archlocation=${dirname}
       fi
   count=$(($count + 1))
   done >> $tempfile
   echo "ARCHIVELOGMODE=true" >> $tempfile
else
   echo "ARCHIVELOGMODE=false" >> $tempfile
fi

# Gather data on redo 
redogroups=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select group# from v\\$logfile;
   exit;
EOF`

redocount=$(echo "$redogroups" | wc -l)
redounique=$(echo "$redogroups" | uniq -u | wc -l)
redopergroup=$(printf "%.0f" $(($redocount / $redounique)))

redosize=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select bytes/1024/1024 from v\\$log;
   exit;
EOF`

sizesum=0
for logsize in $redosize; do
    sizesum=$(( $logsize + $sizesum ))
done

avgsize=$(( $sizesum / $redounique ))

echo "REDOGROUPS=$redounique" >> $tempfile
echo "REDOPERGROUP=$redopergroup" >> $tempfile
echo "REDOSIZE=$avgsize" >> $tempfile

# Gather data on temp tablespace
tempdbfs=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select bytes from v\\$tempfile ;
   exit;
EOF`

if [ -n "$tempdbfs" ]; then
   total=0
   for amount in $tempdbfs; do
       total=$(( $amount + $total ))
   done
   echo "TEMP=true" >> $tempfile
   echo "TEMPSIZE=$total" >> $tempfile
fi

dbcharset=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select value from nls_database_parameters where parameter='NLS_CHARACTERSET';
   exit;
EOF`

echo "DBCHARSET=$dbcharset" >> $tempfile

# Create PFILE if not present
if [ ! -f $ORACLE_HOME/dbs/init${ORACLE_SID}.ora ]; then
   echo "PFILE not found, creating ..."
sqlplus -S / as sysdba << EOF
create PFILE='$ORACLE_HOME/dbs/init${ORACLE_SID}.ora' from SPFILE;
EOF
else
   echo "PFILE found at $ORACLE_HOME/dbs/init${ORACLE_SID}.ora"
fi

if [ -n "$CONFIG_DIR" ]; then
   configDirLoc=$CONFIG_DIR
elif [ "$HOT_BACKUP_FLAG" -eq 1 ]; then
   configDirLoc=$archlocation
else
   configDirLoc=$dbfmountpoint
fi

# Create config directory
if [ -d "$configDirLoc/dbconfig" ]; then
   [ ! -w "$configDirLoc/dbconfig" ] && err_end "Can not write to config directory $configDirLoc/dbconfig"
   echo "DB config directory exists; overwriting..."
else
   echo "DB config directory does not exist; creating ..."
   mkdir $configDirLoc/dbconfig || err_end "Can not create config directory."
fi

# Copy files to config directory
cp $tempfile $configDirLoc/dbconfig/${DBNAME}.dbconfig

[ -f $ORACLE_HOME/network/admin/listener.ora ] && cp $ORACLE_HOME/network/admin/listener.ora $configDirLoc/dbconfig/
[ -f $ORACLE_HOME/network/admin/sqlnet.ora ] && cp $ORACLE_HOME/network/admin/sqlnet.ora $configDirLoc/dbconfig/
[ -f $ORACLE_HOME/network/admin/tnsnames.ora ] && cp $ORACLE_HOME/network/admin/tnsnames.ora $configDirLoc/dbconfig/
[ -f $ORACLE_HOME/dbs/orapw${ORACLE_SID} ] && cp $ORACLE_HOME/dbs/orapw${ORACLE_SID} $configDirLoc/dbconfig/orapw${DBNAME}
[ -f $ORACLE_HOME/dbs/init${ORACLE_SID}.ora ] && cp $ORACLE_HOME/dbs/init${ORACLE_SID}.ora $configDirLoc/dbconfig/init${DBNAME}.ora
[ -f $ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora ] && cp $ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora $configDirLoc/dbconfig/spfile${DBNAME}.ora

if [ -f "$configDirLoc/dbconfig/init${DBNAME}.ora" -a -n "$GLOBAL_SID" ]; then
   EDIT_FILE=$(mktemp)
   cat $configDirLoc/dbconfig/init${DBNAME}.ora | grep -i -e "^$ORACLE_SID" -e "^*." > $EDIT_FILE
   cp $EDIT_FILE $configDirLoc/dbconfig/init${DBNAME}.ora
   rm $EDIT_FILE
fi

echo "Backing up control file ..."
rm -f $configDirLoc/dbconfig/control.bkp
sqlplus -S / as sysdba << EOF
alter database backup controlfile to '$configDirLoc/dbconfig/control.bkp';
EOF

echo "DB ${DBNAME} configuration file: $configDirLoc/dbconfig/${DBNAME}.dbconfig"

cat $configDirLoc/dbconfig/${DBNAME}.dbconfig
rm $tempfile
