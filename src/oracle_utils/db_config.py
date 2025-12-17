import os
import sys
import errno
import json
import getopt
from .oracle_utils import Sqlplus

def print_usage():
    print("Usage: " + sys.argv[0] + " --dir /config/dir --sid ORACLE_SID")
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
    containers = {}
    cfgdir = None
    orasid = None
    quietmode = False
    dbconfig = {'instance': {},
                'database': {},
                'datafiles': [],
                'tempfiles': [],
                'containers': [],
                'log': [],
                'logfile': [],
                'archive': []}

    try:
        options, remainder = getopt.getopt(sys.argv[1:], "hqd:s:", ["dir=", "sid=", "quiet"])
    except getopt.GetoptError as err:
        print("Invalid arguments: %s" % str(err))
        print_usage()

    for opt, arg in options:
        if opt in '-h':
            print_usage()
        elif opt in ('-d', '--dir'):
            cfgdir = arg
        elif opt in ('-s', '--sid'):
            orasid = arg
        elif opt in ('-q', '--quiet'):
            quietmode = True

    if not cfgdir or not orasid:
        print_usage()

    if not os.path.isdir(cfgdir + '/config'):
        try:
            mkdir_p(cfgdir + '/config')
        except OSError as err:
            print("Error: %s" % err)
            sys.exit(1)

    os.environ['ORACLE_SID'] = orasid

    sql_session = Sqlplus()
    sql_session.start()
    instance = sql_session.run_query('select * from v$instance;')
    database = sql_session.run_query('select * from v$database;')
    datafiles = sql_session.run_query('select * from v$datafile;')
    tempfiles = sql_session.run_query('select * from v$tempfile;')
    log = sql_session.run_query('select * from v$log;')
    logfile = sql_session.run_query('select * from v$logfile;')
    archive = sql_session.run_query('select * from v$archive_dest where destination is not null;')
    if database['results'][0]['cdb']:
        if database['results'][0]['cdb'] == "YES":
            containers = sql_session.run_query('select * from v$containers;')
    sql_session.end()

    dbconfig['instance'].update(instance['results'][0])
    dbconfig['database'].update(database['results'][0])
    for x in range(len(datafiles['results'])):
        dbconfig['datafiles'].append(datafiles['results'][x])
    for x in range(len(tempfiles['results'])):
        dbconfig['tempfiles'].append(tempfiles['results'][x])
    if database['results'][0]['cdb']:
        if database['results'][0]['cdb'] == "YES":
            for x in range(len(containers['results'])):
                dbconfig['containers'].append(containers['results'][x])
    for x in range(len(log['results'])):
        dbconfig['log'].append(log['results'][x])
    for x in range(len(logfile['results'])):
        dbconfig['logfile'].append(logfile['results'][x])
    if len(archive['results']) != 0:
        for x in range(len(archive['results'])):
            dbconfig['archive'].append(archive['results'][x])

    dbconfig_file = cfgdir + '/config/' + dbconfig['database']['db_unique_name'] + '.json'

    try:
        with open(dbconfig_file, 'w') as configSaveFile:
            json.dump(dbconfig, configSaveFile, indent=4)
            configSaveFile.write("\n")
            configSaveFile.close()
    except OSError as err:
        print("Could not write config file: %s" % err)
        sys.exit(1)

    if quietmode:
        print(dbconfig_file)
    else:
        print("DB %s configuration file saved at %s" % (dbconfig['database']['db_unique_name'], dbconfig_file))

if __name__ == '__main__':

    try:
        main()
    except SystemExit as e:
        if e.code == 0:
            os._exit(0)
        else:
            os._exit(e.code)
