# oracle-scripts

Database automation scripts.

Currently includes scripts to assist with the creation of a hot backup or incremental merge copy of a database. It creates a directory dbconfig either on the archive log file system (for hot backup mode) or the backup file system (for backup copy mode) that contains information that is helpful in the event a restore is necessary. This information is also used by the [oracle-container-automation](https://github.com/mminichino/oracle-container-automation) tool to create database copies in a container. Note - the S3 backup utility requires the AWS CLI.

To begin hot backup mode:
````
$ ./db-hot-backup.sh -b -s proddb
````

To end hot backup mode:
````
$ ./db-hot-backup.sh -e -s proddb
````

To create an incremental merge copy (and don't catalog the backup):
````
$ ./db-incr-merge.sh -n -s proddb -d /oradb/backup
````

To upload an incremental merge copy to S3:
````
$ ./db-s3-backup.sh -s proddb -d /oradb/cloud -e https://s3.company.com -p authprofile -b bucket
````

To create a new database with archivelog mode enabled:
````
$ ./db-create.sh -a -c -s demodb -d /db01/demodb
````

To remove a database:
````
$ ./db-delete.sh -s demodb
````
