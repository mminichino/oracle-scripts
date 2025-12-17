import os
import sys
import errno
import getopt
from .oracle_utils import Sqlplus

def print_usage():
    print("Usage: " + sys.argv[0] + " -s ORACLE_SID -t backup_tag -d /backup/dir -a | -b")
    sys.exit(1)

def mkdir_p(path):
    try:
        os.makedirs(path)
    except OSError as exc:
        if exc.errno == errno.EEXIST and os.path.isdir(path):
            pass
        else:
            raise

def main():

    options = []
    orasid = None
    bkuptag = None
    bkupdir = None
    arch_mode = False
    bkup_mode = True

    try:
        options, remainder = getopt.getopt(sys.argv[1:], "habs:t:d:", ["archive", "backup", "sid=", "tag=", "dir="])
    except getopt.GetoptError as err:
        print("Invalid arguments: %s" % str(err))
        print_usage()

    for opt, arg in options:
        if opt in '-h':
            print_usage()
        elif opt in ('-s', '--sid'):
            orasid = arg
        elif opt in ('-t', '--tag'):
            bkuptag = arg
        elif opt in ('-d', '--dir'):
            bkupdir = arg
        elif opt in ('-a', '--archive'):
            arch_mode = True
            bkup_mode = False
        elif opt in ('-b', '--backup'):
            bkup_mode = True
            arch_mode = False

    if not orasid or not bkuptag or not bkupdir:
        print_usage()

    os.environ['ORACLE_SID'] = orasid

    if arch_mode:
        if not os.path.isdir(bkupdir + "/archivelog"):
            try:
                mkdir_p(bkupdir + "/archivelog")
            except OSError as err:
                print("Error: %s" % err)
                sys.exit(1)

        arch_script = []
        sql_session = Sqlplus()
        sql_session.start()
        arch_currnt = sql_session.run_query("select thread#, sequence# from v$log where status = 'CURRENT' or status = 'CLEARING_CURRENT' union select thread#, max(sequence#) from v$log where status = 'INACTIVE' group by thread# order by thread#, sequence# ;")
        sql_session.end()

        arch_script.append("run")
        arch_script.append("{")
        arch_script.append("ALLOCATE CHANNEL CH01 DEVICE TYPE DISK FORMAT '" + bkupdir + "/archivelog/%U' ;")
        arch_script.append("SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';")

        for x in range(len(arch_currnt['results'])):
            arch_script.append("BACKUP AS COPY ARCHIVELOG SEQUENCE " + arch_currnt['results'][x]['sequence#'] + " THREAD " + arch_currnt['results'][x]['thread#'] + ";")

        arch_script.append("CHANGE COPY OF ARCHIVELOG LIKE '" + bkupdir + "/archivelog/%' UNCATALOG ;")
        arch_script.append("}")

        for x in range(len(arch_script)):
            print(arch_script[x])

    if bkup_mode:
        bkup_script = []
        sql_session = Sqlplus()
        sql_session.start()
        dbinfo = sql_session.run_query("select * from v$database;")
        sql_session.end()

        dbname = dbinfo['results'][0]['db_unique_name']

        if not os.path.isdir(bkupdir + "/" + dbname):
            try:
                mkdir_p(bkupdir + "/" + dbname)
            except OSError as err:
                print("Error: %s" % err)
                sys.exit(1)

        bkup_script.append("run")
        bkup_script.append("{")
        bkup_script.append("set nocfau;")
        bkup_script.append("ALLOCATE CHANNEL CH01 DEVICE TYPE DISK FORMAT '" + bkupdir + "/" + dbname + "/%U';")
        bkup_script.append("CROSSCHECK COPY TAG '" + bkuptag + "';")
        bkup_script.append("CROSSCHECK BACKUP TAG '" + bkuptag + "';")
        bkup_script.append("CATALOG start with '" + bkupdir + "/" + dbname + "' NOPROMPT ;")
        bkup_script.append("CATALOG start with '" + bkupdir + "/archivelog' NOPROMPT ;")
        bkup_script.append("BACKUP CHANNEL CH01 INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG '" + bkuptag + "' DATABASE ;")
        bkup_script.append("RECOVER COPY OF DATABASE WITH TAG '" + bkuptag + "';")
        bkup_script.append("BACKUP AS COPY CURRENT CONTROLFILE TAG '" + bkuptag + "' FORMAT '" + bkupdir + "/" + dbname + "/control01.ctl' REUSE ;")
        bkup_script.append("DELETE NOPROMPT BACKUPSET TAG '" + bkuptag + "';")
        bkup_script.append("CHANGE COPY OF DATABASE TAG '" + bkuptag + "' UNCATALOG ;")
        bkup_script.append("CHANGE COPY OF CONTROLFILE TAG '" + bkuptag + "' UNCATALOG ;")
        bkup_script.append("CHANGE COPY OF ARCHIVELOG LIKE '" + bkupdir + "/archivelog/%' UNCATALOG ;")
        bkup_script.append("}")

        for x in range(len(bkup_script)):
            print(bkup_script[x])

if __name__ == '__main__':

    try:
        main()
    except SystemExit as e:
        if e.code == 0:
            os._exit(0)
        else:
            os._exit(e.code)