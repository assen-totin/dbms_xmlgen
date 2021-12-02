# Summary

This is a limited implementation of the DBMS_XMLGEN PL/SQL package for MariaDB.

Its main purpose is to run a query and return the result set in a structured form as XML.

# Procedures and Functions

Names and prototypes follow the original ones.

Only the following procedures and functions from the original package are implemented:

- FUNCTION NEWCONTEXT (query VARCHAR2) RETURN VARCHAR2
- PROCEDURE SETNULLHANDLING(ctx IN VARCHAR2, flag IN NUMBER)
- PROCEDURE SETROWTAG (ctx IN VARCHAR2, rowTagName IN VARCHAR2)
- PROCEDURE SETROWSETTAG (ctx IN VARCHAR2, rowSetTagName IN VARCHAR2)
- PROCEDURE CLOSECONTEXT(ctx IN VARCHAR2)
- FUNCTION GETXML (ctx VARCHAR2) RETURN CLOB

One additional procedure is implemented:

- PROCEDURE RUN(ctx IN VARCHAR2)

A number of other internal procedures and functions exists. See below for engineering details. 

# Quick Start

A minimal run consists of the following:

```
-- Set mode
SET SQL_MODE=Oracle;

-- Create new context from a query
SELECT DBMS_XMLGEN.NEWCONTEXT('SELECT * FROM t1') INTO @ctx1;

-- Run the context
CALL DBMS_XMLGEN.RUN(@ctx1);

-- Get the XML
SELECT DBMS_XMLGEN.GETXML(@ctx1) INTO @xml1;

-- Print the XML
SELECT @xml1;
```

# Usage

## Installing the Package

To install the package, load the provided SQL file:

`mariadb some_db_name < package.sql`

## Description of Procedures and Functions

### FUNCTION NEWCONTEXT (query VARCHAR2) RETURN VARCHAR2

Initialises a new context from the provided query. Returns the context identifier. 

The context is specific to the session. Multiple contexts may coexist in the same session. 

### PROCEDURE SETNULLHANDLING(ctx IN VARCHAR2, flag IN NUMBER)

Sets up the handling of NULL values for the given context. The flag may have the following values:

- 0: The NULL values will be skipped from the output. This is the default.
- 1: An empty tag with the `xsi:nil="true"` will be produced for the NULL value.
- 2: An empty tag will be produced for the NULL value.

### PROCEDURE SETROWTAG (ctx IN VARCHAR2, rowTagName IN VARCHAR2)

Sets up the row tag for the given context. The default is to use `ROW`. If set to NULL, the row tag will be omitted. 

### PROCEDURE SETROWSETTAG (ctx IN VARCHAR2, rowSetTagName IN VARCHAR2)

Sets up the rowset tag for the given context. The default is to use `ROWSET`. If set to NULL, the rowset tag will be omitted. 

### PROCEDURE RUN(ctx IN VARCHAR2)

Runs the query and stores internally the produced XML. This procedure is not present in the original package, but is required to be run prior to XML collection.

### FUNCTION GETXML (ctx VARCHAR2) RETURN CLOB

Gets back the XML for the query result set. If invoked before `RUN()`, it will return an error message asking you to first run the context.

### PROCEDURE CLOSECONTEXT(ctx IN VARCHAR2)

Closes the context and removes it. All contexts for a session will be automatically purged one the session is terminated. 

## Differences from the Original

The package differs from the original in the following:

- Only a subset of the original procedures and functions are implemented.
- No custom data type `ctxHandle` is exposed for the context, because MariaDB does not support custom data types. `VARCHAR2` is used instead.
- The `RUN()` procedure was added due to the restrictions of MariaDB not to allow dynamic SQL in the path of a stored function (the XML collection is done by the `GETXML()` function). This procedure must be invoked to generate the XML prior to its collection. 

# Hacking

## Structure

The package is implemented with two types of procedures and functions:

- External, which mimic the original ones (plus the extra `RUN()` procedure). These are intended to be called from outside. Usually they make a single call to an internal procedure or function. There is a many-to-one mapping: many external procedures will call the same internal one to set various properties of the context. 
- Internal, which are used to do the actual work and know the inner organisation of the data.

This separation allows the inner workings of the package to be changed as desired without touching the external ones.

## The Context

The context storage is implemented as a temporary table. Each context is represented by a single row in it. The following values are stored on this row:

- The context ID: a string that is composed to guarantee a unique name inside the session.
- The context value: a JSON string.
- The XML code for the context: only filled up once the `RUN()` procedure is called.

When a new context is created from a query, a JSON object is constructed for it. It contains the query and the default values for the supported properties:

- `query`: contains the text of the query to run.
- `null_handling`: defines the desired handling of NULL values in the result set. Initially set to `0`.
- `row_tag`: defines the desired row tag. Initially set to `ROW`.
- `rowset_tag`: defines the desired rowset tag. Initially set to `ROWSET`.

## XML Generation

Due to the restrictions MariaDB has on running dynamic SQL, the generation of the XML is a four-step process done by the `RUN()` procedure:

- The query is run and the result set is materialised into a table. This is done by running the query with `CREATE TABLE AS ...`. An regular (non-temporary) table is used, because MariaDB does not provide a mechanism to read the column names of a temporary table from INFORMATION_SCHEMA and the `SHOW` statements (which can still be used for this purpose) are not allowed in stored procedures. The table will be removed automatically after the XML is generated. 
- The list of column names is obtained from the table. This is necessary, because MariaDB does not provide a DBMS_SQL package and does not support any kind of numeric cursors that would allow the column names to obtained from it. 
- Using the column names, a query is constructed that retrieves each row from the materialisation table in the form of a concatenated XML. Conditionals are added there to implement the desired NULL handling. Because MariaDB does not provide a way to retrieve a multi-row result from a dynamic query (no dynamic cursors and no arrays are supported), the XML for each row from the materialised table is written to another temporary table with a single column having a fixed name. 
- All rows from the temporary table are read, concatenated, wrapped with XML schema and rowset tags and written to the context.

Once the XML is written there, it is available for picking up by the `GETXML()` function.

# Testing

The simple test plan below does the following:

- Sets SQL mode
- Creates a new context from a query (the table to query must already exist).
- Sets the NULL handling, the row tag and the rowset tag.
- Updates the rowset tag.
- Read the XML before calling the `RUN()` procedure. An error message should be returned.
- Calls the `RUN()` procedure.
- Reads again the XML. This time it should be returned properly. 
- Cleans up.

```
-- Set mode
SET SQL_MODE=Oracle;

-- Create new context from a query
SELECT DBMS_XMLGEN.NEWCONTEXT('SELECT * FROM t1') INTO @ctx1;

-- Set the NULL handling in the context
CALL DBMS_XMLGEN.SETNULLHANDLING(@ctx1, 2);

-- Set the row tag in the context
CALL DBMS_XMLGEN.SETROWTAG(@ctx1, 'MY-ROW-TAG');

-- Set the row set tag in the context
CALL DBMS_XMLGEN.SETROWSETTAG(@ctx1, 'ROWSET-TAG');

-- Update a value in context that was previously set
CALL DBMS_XMLGEN.SETROWSETTAG(@ctx1, 'MY-ROWSET-TAG');

-- Verify the context is correct
SELECT * FROM dbms_xmlgen WHERE ctx=@ctx1;

-- Get the XML before running the ciontext
SELECT DBMS_XMLGEN.GETXML(@ctx1) INTO @xml1;

-- Print the XML - should be an error message asking to run the context first
SELECT @xml1;

-- Run the context
CALL DBMS_XMLGEN.RUN(@ctx1);

-- Get the XML after running the ciontext
SELECT DBMS_XMLGEN.GETXML(@ctx1) INTO @xml1;

-- Print the XML again
SELECT @xml1;

-- Remove the context
CALL DBMS_XMLGEN.CLOSECONTEXT(@ctx1);
```

Further test cases should check:

- Check the work of default values: same as above without setting the custom attributes into context. 
- Proper work of parallel contexts: create two contexts, initialise each one, run them one by one, fetch the XML. There shoudl be no cross-interference between them. 

# Know Issues

The following issues are currently known:

- Setting NULL in `SETROWTAG()` and `SETROWSETTAG()` procedures will not skip the respective tag, but will set it to the text `null`. This is due to MariaDB bug in processing JSON strings that have a propery with a NULL value. See https://jira.mariadb.org/browse/MDEV-27151 for details.

# Support

This product has no official support from MariaDB.

# License

This product is licensed under the GNU General Public License, version 2.

