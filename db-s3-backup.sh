#!/bin/sh

SCRIPTLOC=$(cd "$(dirname $0)" && pwd)
[ ! -d $SCRIPTLOC/log ] && mkdir $SCRIPTLOC/log
LOGFILE=$SCRIPTLOC/log/sql.trc
HOSTNAME=$(uname -n)
BACKUP_BUCKET="oracle_backup"
SID_ARG=""
BACKUP_DIR=""

log_output() {
    DATE=$(date '+%m-%d-%y_%H:%M:%S')
    while read line; do
        [ -z "$line" ] && continue
        echo "$DATE $HOSTNAME: $line" >> $LOGFILE
    done
}

err_exit() {
   DATE=$(date '+%m%d%y-%H%M%S')" "$(uname -n)
   LEVEL="ERROR"
   if [ -n "$2" ]; then
      if [ "$2" -eq 0 ]; then
         LEVEL="INFO"
      fi
   fi
   if [ -n "$1" ]; then
      echo "${LEVEL}: $1" 2>&1 | log_output
      echo "$1"
   else
      echo "Usage: $0 -s ORACLE_SID -b | -e | -c | -q"
   fi
   if [ -n "$2" ]; then
      exit $2
   else
      exit 1
   fi
}

if [ -z "$(which stat)" ]; then
   err_exit "This script requires the stat utility."
fi

while getopts "s:d:b:t:" opt
do
  case $opt in
    s)
      SID_ARG=$OPTARG
      ;;
    d)
      BACKUP_DIR=$OPTARG
      ;;
    b)
      BACKUP_BUCKET=$OPTARG
      ;;
    t)
      BACKUP_TAG=$OPTARG
      ;;
    \?)
      err_exit
      ;;
  esac
done

if [ -z "$SID_ARG" ] || [ -z "$BACKUP_DIR" ]; then
  print_usage
  err_exit "SID and backup directory arguments are required."
fi

export ORACLE_SID="${SID_ARG}"

[ -z "$BACKUP_TAG" ] && BACKUP_TAG=incrmrg_$ORACLE_SID

if [ "$(stat -t -c '%u' /etc/oratab)" != "$(id -u)" ]; then
   err_exit "This script should be run as the oracle user."
fi

if [ ! -d "$BACKUP_DIR" ];then
   err_exit "Backup directory $BACKUP_DIR does not exist."
fi

if [ -z "$ORACLE_SID" ] && [ -z "$(which sqlplus 2>/dev/null)" ]; then
   err_exit "Environment not properly set."
fi

if [ -z "$(which aws 2>/dev/null)" ]; then
   err_exit "AWS CLI is required."
fi

aws s3 ls > /dev/null 2>&1

if [ $? -ne 0 ]; then
   err_exit "Can not list S3 buckets"
fi

aws s3api head-bucket --bucket "$BACKUP_BUCKET" > /dev/null 2>&1

if [ $? -ne 0 ]; then
   err_exit "Failed to access bucket $BACKUP_BUCKET - missing or inaccessible."
fi

echo "Running incremental merge backup to $BACKUP_DIR"
$SCRIPTLOC/db-incr-merge.sh -s "$ORACLE_SID" -d "$BACKUP_DIR" -t "$BACKUP_TAG"

echo "Copying backup to S3 bucket $BACKUP_BUCKET"

aws s3 rm "s3://$BACKUP_BUCKET/archivelog/" --recursive 2>&1

if [ $? -ne 0 ]; then
   err_exit "Failed to copy backup files to S3 bucket $BACKUP_BUCKET"
fi

cd "$BACKUP_DIR" 2>/dev/null || err_exit "Can not change to backup directory $BACKUP_DIR"
aws s3 cp . "s3://$BACKUP_BUCKET" --recursive --no-progress 2>&1

if [ $? -ne 0 ]; then
   err_exit "Failed to copy backup files to S3 bucket $BACKUP_BUCKET"
fi

echo "Backup and transfer complete."
