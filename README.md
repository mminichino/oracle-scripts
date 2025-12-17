# oracle-scripts

Database automation scripts.

Includes scripts to assist with the creation of a hot backup or incremental merge copy of a database. It creates a directory dbconfig either on the archive log file system (for hot backup mode) or the backup file system (for backup copy mode) that contains information that is helpful in the event a restore is necessary. This information is also used by the [oracle-container-automation](https://github.com/mminichino/oracle-container-automation) tool to create database copies in a container. Note - the S3 backup utility requires the AWS CLI.

To begin hot backup mode:
```shell
./db-hot-backup.sh -b -s proddb
```

To end hot backup mode:
```shell
./db-hot-backup.sh -e -s proddb
```

To create an incremental merge copy (and don't catalog the backup):
```shell
./db-incr-merge.sh -s proddb -d /oradb/backup
```

To upload an incremental merge copy to S3:
```shell
./db-s3-backup.sh -s proddb -d /oradb/cloud -e https://s3.company.com -p authprofile -b bucket
```

To create a new database with archivelog mode enabled:
```shell
./db-create.sh -a -c -s demodb -d /db01/demodb
```

To remove a database:
```shell
./db-delete.sh -s demodb
```

To set up Data Guard:

On the primary side:
```shell
./db-dg-prep.sh -p oracle_sid -h remote_host_name
```

On the secondary side:
```shell
./db-dg-prep.sh -p oracle_sid -h primary_host_name -r
```

To convert a physical standby to logical standby:

On the secondary side stop log apply:
```shell
./db-dg-prep.sh -p oracle_sid -s -r
```

On the primary side setup LogMiner:
```shell
./db-dg-prep.sh -p oracle_sid -m
```

On the secondary side convert the physical standby to logical standby:
```shell
./db-dg-prep.sh -p oracle_sid -l -r
```

To recreate a physical standby database:

Drop the standby database (this is a destructive action that can not be undone)
```shell
./db-dg-prep.sh -p oracle_sid -d
```

On the primary database host, copy the configuration to the secondary:
```shell
./db-dg-prep.sh -p oracle_sid -h remote_host_name -x
```

Recreate the standby database:
```shell
./db-dg-prep.sh -p oracle_sid -h primary_host_name -r
```

To online relocate a database supply a target root directory. Subdirectories will be created for data files, the FRA, and archive logs. This supports FS to FS, ASM to FS, and FS to ASM.
```shell
./db-file-move.sh -s oracle_sid -d /path
```

To test a move without actually moving anything:
```shell
./db-file-move.sh -s oracle_sid -d /path -t
```

Use the prompt option to ask to move each data file type. If you respond "no" then it will skip that data file type.
```shell
./db-file-move.sh -s oracle_sid -d /path -p
```

To perform a move of one file type where the destination directory is a full path (no subdirectories are created - this will automatically enable prompting, and it will exit after finishing a file type relocation):
```shell
./db-file-move.sh -s oracle_sid -d /path -f
```
