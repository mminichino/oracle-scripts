oracle_utils: local sqlplus query module
========================================

Python module to automate the interaction with sqlplus for database scripting. It is designed to connect to a local database instance as defined by the ORACLE_SID environment variable.

The sqlplus program is called once and run in a subprocess so multiple queries can be quickly run. Performance is much better than Bash with ````cat <<EOF```` for integrating database data into scripts. The query results are returned in JSON format.

Example
-------

```python
import oracle_utils
import json

sql_session = oracle_utils.Sqlplus()
sql_session.start()
result = sql_session.run_query('select * from dual;')
print(json.dumps(result, indent=4))
sql_session.end()
```

You can pass a query to the module if you want to only execute one query and output the results to the terminal:

```python
oracle_utils.Sqlplus(query="select * from v$instance;")
```

This also enables a Bash one-linter to run a quick query:

````
$ python -c "import oracle_utils; oracle_utils.sqlplus(query='select * from v\$instance;')"
````
