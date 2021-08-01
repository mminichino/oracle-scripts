# Oracle Python Utilities Library
#
import json
import os
import fcntl
import subprocess
import queue
import threading

class OracleError(Exception):

    def __init__(self, sp, message="Query Exception"):
        self.sp = sp
        self.message = message
        self.sp.end()
        super().__init__(self.message)

class GeneralError(Exception):

    def __init__(self, sp, message="General Exception"):
        self.sp = sp
        self.message = message
        if self.sp.p:
            self.sp.end()
        super().__init__(self.message)

class sqlplus:

    def __init__(self):
        self.p = None
        self.sid = None
        self.out_thread = None
        self.err_thread = None
        self.out_queue = queue.Queue()
        self.err_queue = queue.Queue()

        if os.getenv('ORACLE_SID'):
            self.sid = os.getenv('ORACLE_SID')
            print(self.sid)

    def unblock(self, fd):
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        flags = flags | os.O_NONBLOCK
        fcntl.fcntl(fd, fcntl.F_SETFL, flags)

    def stdout_reader(self):
        for line in iter(self.p.stdout.readline, b''):
            self.out_queue.put(line.decode('utf-8'))

    def stderr_reader(self):
        for line in iter(self.p.stderr.readline, b''):
            self.err_queue.put(line.decode('utf-8'))

    def check_repeat(self, text, char):
        for x in range(len(text)):
            if text[x] != text[0] or text[x] != char:
                return False
        return True

    def start(self):
        self.p = subprocess.Popen(['sqlplus', '-S', '/', 'as', 'sysdba'],
                                  stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE)

        self.p.stdin.write('{}\n'.format('set colsep ,').encode('utf-8'))
        self.p.stdin.write('{}\n'.format('set trim on').encode('utf-8'))
        self.p.stdin.write('{}\n'.format('set linesize 32767;').encode('utf-8'))
        self.p.stdin.write('{}\n'.format('set pagesize 50000;').encode('utf-8'))
        self.p.stdin.write('{}\n'.format('set feedback off;').encode('utf-8'))
        self.p.stdin.write('{}\n'.format('set serveroutput on;').encode('utf-8'))
        self.p.stdin.write('{}\n'.format('set headsep off').encode('utf-8'))
        self.p.stdin.write('{}\n'.format('set embedded on').encode('utf-8'))
        self.p.stdin.flush()
        self.out_thread = threading.Thread(target=self.stdout_reader)
        self.err_thread = threading.Thread(target=self.stderr_reader)
        self.out_thread.start()
        self.err_thread.start()

    def run_query(self, query, gather=True):
        output = True
        linenum = 0
        results = {'results': []}
        heading = []

        if not self.p:
            raise GeneralError(self, "Run start method before query")

        self.p.stdin.write('{}\n'.format(query).encode('utf-8'))
        self.p.stdin.write('{}\n'.format("begin dbms_output.put_line('---ENDQUERY---'); end;").encode('utf-8'))
        self.p.stdin.write('{}\n'.format("/").encode('utf-8'))
        self.p.stdin.flush()

        while output:
            try:
                line = self.out_queue.get(block=False)
                linestr = '{0}'.format(line).strip()

                if len(linestr) == 0:
                    continue

                linearray = linestr.split(',')
                linenum = linenum + 1

                if linestr == "---ENDQUERY---":
                    break

                if self.check_repeat(linearray[0], '-'):
                    continue

                if linearray[0].startswith('ORA-'):
                    raise OracleError(self, linearray[0])

                if gather and linenum == 1:
                    for x in range(len(linearray)):
                        heading.append(linearray[x].strip())

                if gather and linenum > 1:
                    rowdata = {}
                    for x in range(len(linearray)):
                        rowdata.update({heading[x]: linearray[x].strip()})
                    results['results'].append(rowdata)

            except queue.Empty:
                pass

            try:
                line = self.err_queue.get(block=False)
                linestr = '{0}'.format(line).strip()
                raise GeneralError(self, linestr)
            except queue.Empty:
                pass

        return results

    def end(self):
        self.p.stdin.write('{}\n'.format("exit").encode('utf-8'))
        self.p.stdin.close()
        self.p.terminate()
        self.p.wait(timeout=0.2)
        self.out_thread.join()
        self.err_thread.join()


