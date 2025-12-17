import os
import sys
import json
import getopt

def print_usage():
    print("Usage: " + sys.argv[0] + " --file /config/dir/config/db.json query")
    sys.exit(1)

def main():

    cfgfile = None
    options = []
    remainder = []
    dbconfig = {}

    try:
        options, remainder = getopt.getopt(sys.argv[1:], "hf:", ["file=", ])
    except getopt.GetoptError as err:
        print("Invalid arguments: %s" % str(err))
        print_usage()

    for opt, arg in options:
        if opt in '-h':
            print_usage()
        elif opt in ('-f', '--file'):
            cfgfile = arg

    if not cfgfile:
        print_usage()

    try:
        with open(cfgfile, 'r') as configReadFile:
            try:
                dbconfig = json.load(configReadFile)
            except ValueError as err:
                print("Configuration file does not contain valid JSON data: %s" % err)
                sys.exit(1)
    except OSError as err:
        print("Could not read configuration file: %s" % err)
        sys.exit(1)

    for query in remainder:
        if query == "dbname":
            print(dbconfig['database']['db_unique_name'])
        elif query == "archivemode":
            if dbconfig['database']['log_mode'] == "ARCHIVELOG":
                sys.exit(0)
            else:
                sys.exit(1)
        elif query == "dbversion":
            dbversion = dbconfig['instance']['version']
            dbrev = dbversion.split('.')
            print(dbrev[0])
        elif query == "dbrev":
            dbversion = dbconfig['instance']['version_full']
            dbrev = dbversion.split('.')
            print(dbrev[1])
        else:
            print("Unsupported query: %s" % query)
            sys.exit(1)

if __name__ == '__main__':

    try:
        main()
    except SystemExit as e:
        if e.code == 0:
            os._exit(0)
        else:
            os._exit(e.code)