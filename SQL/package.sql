/* 
    A limited implementation of DBMS_XMLGEN PL/SQL package for MariaDB.

    Copyright (C) 2021 Assen Totin, MariaDB

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; version 2 of the License.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*/

SET SQL_MODE=Oracle;
delimiter //
CREATE OR REPLACE PACKAGE DBMS_XMLGEN
AS
    PROCEDURE _CTX_CREATE(query IN VARCHAR2, o_ctx OUT VARCHAR2);
    PROCEDURE _CTX_UPDATE_VARCHAR(i_ctx IN VARCHAR2, k IN VARCHAR2, v IN VARCHAR2);
    PROCEDURE _CTX_UPDATE_NUMBER(i_ctx IN VARCHAR2, k IN VARCHAR2, v IN NUMBER);
    PROCEDURE _CTX_DESTROY(i_ctx IN VARCHAR2);
    PROCEDURE _CTX_RUN(i_ctx IN VARCHAR2);
    PROCEDURE _CTX_GETXML(i_ctx IN VARCHAR2, xml_out OUT TEXT);
    FUNCTION NEWCONTEXT (query VARCHAR2) RETURN VARCHAR2;
    PROCEDURE SETNULLHANDLING(ctx IN VARCHAR2, flag IN NUMBER);
    PROCEDURE SETROWTAG (ctx IN VARCHAR2, rowTagName IN VARCHAR2);
    PROCEDURE SETROWSETTAG (ctx IN VARCHAR2, rowSetTagName IN VARCHAR2);
    PROCEDURE CLOSECONTEXT(ctx IN VARCHAR2);
    FUNCTION GETXML (ctx VARCHAR2) RETURN CLOB;
    PROCEDURE RUN(ctx IN VARCHAR2);
END
//


CREATE OR REPLACE PACKAGE BODY DBMS_XMLGEN
IS
--
-- Procedure: _CTX_CREATE()
-- Internal procedure to create the context and write it to the context table.
-- Returns:
-- ctx VARCHAR2 - The handle to the context that was created.
--
    PROCEDURE _CTX_CREATE(query IN VARCHAR2, o_ctx OUT VARCHAR2)
    IS
    BEGIN
        -- Create the temp table to hold contexts if it does not already exist
        CREATE TEMPORARY TABLE IF NOT EXISTS dbms_xmlgen (ctx VARCHAR(255) NOT NULL DEFAULT '' PRIMARY KEY, val TEXT, xml TEXT);
        SELECT REPLACE(CONCAT('dbms_xmlgen_', UNIX_TIMESTAMP(NOW(6))), '.', '_') INTO o_ctx FROM DUAL;
        INSERT INTO dbms_xmlgen (ctx, val) VALUES (o_ctx, JSON_OBJECT('query', query, 'row_tag', 'ROW', 'rowset_tag', 'ROWSET', 'null_handling', 0));
    END;

--
-- Procedure: _CTX_UPDATE_VARCHAR()
-- Internal procedure to update the context with a given key and a VARCHAR value.
-- Arguments:
-- i_ctx VARCHAR2 - The context to operate on.
-- k VARCHAR2 - The key to add to context (or update if it exists).
-- v VARCHAR2 - The value to set for the key.
--
    PROCEDURE _CTX_UPDATE_VARCHAR(i_ctx IN VARCHAR2, i_k IN VARCHAR2, i_v IN VARCHAR2)
    IS 
        l_path    VARCHAR(255);
    BEGIN
        l_path := '$.' || i_k;
        UPDATE dbms_xmlgen SET val = JSON_SET(val, l_path, i_v) WHERE ctx=i_ctx;
    END;

--
-- Procedure: _CTX_UPDATE_NUMBER()
-- Internal procedure to update the context with a given key and a NUMBER value.
-- Arguments:
-- i_ctx VARCHAR2 - The context to operate on.
-- k NUMBER - The key to add to context (or update if it exists).
-- v VARCHAR2 - The value to set for the key.
--
    PROCEDURE _CTX_UPDATE_NUMBER(i_ctx IN VARCHAR2, i_k IN VARCHAR2, i_v IN NUMBER)
    IS
        l_path    VARCHAR(255);
    BEGIN
        l_path := '$.' || i_k;
        UPDATE dbms_xmlgen SET val = JSON_SET(val, l_path, i_v) WHERE ctx=i_ctx;
    END;


--
-- Procedure: _CTX_DESTROY()
-- Internal procedure to destroy the context.
-- Arguments:
-- i_ctx VARCHAR2 - The context to operate on.
--
    PROCEDURE _CTX_DESTROY(i_ctx IN VARCHAR2)
    IS
    BEGIN
        DELETE FROM dbms_xmlgen WHERE ctx=i_ctx;
    END;


--
-- Procedure: _CTX_RUN()
-- Procedure to execute the query from the context, obtain the output in XML form and save it back into it.
-- Arguments:
-- i_ctx VARCHAR2 - The context to operate on.
--
    PROCEDURE _CTX_RUN(i_ctx IN VARCHAR2)
    IS
        ctx_query    TEXT;
        ctx_null_handling    NUMBER;
        ctx_row_tag    VARCHAR2(255);
        ctx_rowset_tag    VARCHAR2(255);

        l_col_name    VARCHAR(255);
        l_col_list    TEXT;
        l_query    TEXT;
        l_row    TEXT;
        l_xml    TEXT;

        CURSOR cur_c IS SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='dbms_xmlgen_data';
        CURSOR cur_d IS SELECT datarow FROM dbms_xmlgen_temp;
    BEGIN
        -- Get the data from the context
        SELECT JSON_VALUE(val, '$.query'), JSON_VALUE(val, '$.null_handling'), JSON_VALUE(val, '$.row_tag'), JSON_VALUE(val, '$.rowset_tag') INTO ctx_query, ctx_null_handling, ctx_row_tag, ctx_rowset_tag FROM dbms_xmlgen WHERE ctx=i_ctx;

        -- Prepare defaults  XML
        l_xml := '<?xml version="1.0"?>';

        IF ctx_rowset_tag IS NOT NULL THEN
            l_xml := l_xml || '<' || ctx_rowset_tag || '>';
        END IF;

        -- NB: MariaDB lacks a DBMS_SQL package, hence we cannot fetch the column names from a cursor;
        -- It also has no support for fetching the column list of a temporary table from INFORMATION_SCHEMA
        -- and does not allow the usage of SHOW queries in stored procedures;
        -- we therefore materialsie the query into a permanent table from which we can get the column names.

        -- NB: MariaDB lacks dynamic SQL for multi-row queries (no dynamic curros and no arays to facilitate EXECUTE IMMEDIATE,
        -- hence we cannot even randomise the materialised table name, which makes this procedure non-reentrant.
        DROP TABLE IF EXISTS dbms_xmlgen_data;
        EXECUTE IMMEDIATE 'CREATE TABLE dbms_xmlgen_data AS ' || ctx_query;

        -- Get the column names and prepare the data row retrieval query.
        -- Our basic query comes in the form or CONCAT('<col1>', col1, '</col1>',...)
        -- To add NULL handling, we need to test each column for NULL with ISNULL() and then:
        --    either return the above CONCAT() (if the cell is not NULL), or
        --    construct an alternative string depending on the selected NULL handling mode.

        l_col_list := '';
        OPEN cur_c;
        LOOP
            FETCH cur_c INTO l_col_name;
            EXIT WHEN cur_c%NOTFOUND;

            IF LENGTH(l_col_list) > 0 THEN
                l_col_list := l_col_list || ',';
            END IF;

            l_col_list := l_col_list || 'IF(ISNULL(' || l_col_name || '),';
            IF ctx_null_handling = 0 THEN
                l_col_list := l_col_list || ''''',';
            ELSIF ctx_null_handling = 1 THEN
                l_col_list := l_col_list || 'CONCAT(''<' || l_col_name || ' xsi:nil="true"/>''),';
            ELSIF ctx_null_handling = 2 THEN
                l_col_list := l_col_list || 'CONCAT(''<' || l_col_name || '/>''),';
            END IF;
            l_col_list := l_col_list || 'CONCAT(''<' || l_col_name || '>'',' || l_col_name || ',''</' || l_col_name || '>''))';
        END LOOP;
        CLOSE cur_c;
        l_query := 'CONCAT(' || l_col_list || ')';

        -- NB: Because we can't use a multi-row dynamic query to fetch the data from the materialised table,
        -- we need an internediate step that will create each XML row into a temporary table.
        -- At least we can use a temporary table here.
        -- NB: Randomising the name is useless as the fixed name data table already made this one non-reentrant;
        -- also, using a fixed name allows us to use one-step fetch via statuc cursor; 
        -- otherwise we'd need to do a row-by-row read using EXECUTE IMMEDIATE, further slowing us down.
        DROP TABLE IF EXISTS dbms_xmlgen_temp;
        EXECUTE IMMEDIATE 'CREATE TABLE dbms_xmlgen_temp AS SELECT ' || l_query || ' AS datarow FROM dbms_xmlgen_data';

        -- Get the data
        OPEN cur_d;
        LOOP
            FETCH cur_d INTO l_row;
            EXIT WHEN cur_d%NOTFOUND;

            IF ctx_row_tag IS NOT NULL THEN
                l_xml := l_xml || '<' || ctx_row_tag || '>';
            END IF;
            l_xml := l_xml || l_row;
            IF ctx_row_tag IS NOT NULL THEN
                l_xml := l_xml || '</' || ctx_row_tag || '>';
            END IF;
        END LOOP;
        CLOSE cur_d;

        IF ctx_rowset_tag IS NOT NULL THEN
            l_xml := l_xml || '</' || ctx_rowset_tag || '>';
        END IF;

        -- Save back into context table
        UPDATE dbms_xmlgen SET xml=l_xml;

        -- Clean up
        DROP TABLE IF EXISTS dbms_xmlgen_data;
        DROP TABLE IF EXISTS dbms_xmlgen_temp;
    END;

--
-- Procedure: _CTX_GETXML()
-- Procedure to execute the query from the context and obtain the output in XML form.
-- Arguments:
-- i_ctx VARCHAR2 - The context to operate on.
-- Returns:
-- o_xml CLOB - The result of the query in the context, formatted as XML.
--
    PROCEDURE _CTX_GETXML(i_ctx IN VARCHAR2, o_xml OUT TEXT)
    IS
    BEGIN
        SELECT xml FROM dbms_xmlgen WHERE ctx=i_ctx INTO o_xml;
        IF o_xml IS NULL THEN
            o_xml := 'ERROR: No XML exists. To generate the XML, run CALL DBMS_XMLGEN.RUN(ctx) first.';
        END IF;
    END;

--
-- Function: NEWCONTEXT()
-- Function to create a new context from a SQL query.
-- Arguments:
-- query VARCHAR2 - The query to execute once the context is complete.
-- Returns:
-- VARCHAR2 - The handle to the context that was created.
--
    FUNCTION NEWCONTEXT (query VARCHAR2) RETURN VARCHAR2
    IS
        ctx    VARCHAR2(255);
    BEGIN
        CALL DBMS_XMLGEN._CTX_CREATE (query, ctx);
        RETURN ctx;
    END;

--
-- Procedure: SETNULLHANDLING()
-- Procedure to set the NULL handling in the context.
-- Arguments:
-- ctx VARCHAR2 - The context to operate on.
-- flag NUMBER - Indicator of how to handle the NULL values: 0 (skip), 1 (set "xsi:nil="true" attribute) or 2 (empty tag)
--
    PROCEDURE SETNULLHANDLING(ctx IN VARCHAR2, flag IN NUMBER)
    IS
    BEGIN
        CALL DBMS_XMLGEN._CTX_UPDATE_NUMBER (ctx, 'null_handling', flag);
    END;

--
-- Procedure: SETROWTAG()
-- Procedure to set the row tag in the context.
-- Arguments:
-- ctx VARCHAR2 - The context to operate on.
--
    PROCEDURE SETROWTAG (ctx IN VARCHAR2, rowTagName IN VARCHAR2)
    IS
    BEGIN
        CALL DBMS_XMLGEN._CTX_UPDATE_VARCHAR (ctx, 'row_tag', rowTagName);
    END;

--
-- Procedure: SETROWSETTAG()
-- Procedure to set the row set tag in the context.
-- Arguments:
-- ctx VARCHAR2 - The context to operate on.
--
    PROCEDURE SETROWSETTAG (ctx IN VARCHAR2, rowSetTagName IN VARCHAR2)
    IS
    BEGIN
        CALL DBMS_XMLGEN._CTX_UPDATE_VARCHAR (ctx, 'rowset_tag', rowSetTagName);
    END;

--
-- Procedure: CLOSECONTEXT()
-- Procedure to destroy the context.
-- Arguments:
-- ctx VARCHAR2 - The context to operate on.
--
    PROCEDURE CLOSECONTEXT(ctx IN VARCHAR2)
    IS
    BEGIN
        CALL DBMS_XMLGEN._CTX_DESTROY (ctx);
    END;

--
-- Function: GETXML()
-- Function to get the XML.
-- Arguments:
-- ctx VARCHAR2 - The context to operate on.
--
    FUNCTION GETXML (ctx VARCHAR2) RETURN CLOB
    IS
        xml    CLOB;
    BEGIN
        CALL DBMS_XMLGEN._CTX_GETXML (ctx, xml);
        RETURN xml;
    END;

--
-- Procedure: RUN()
-- Procedure to execute the query from the context and obtain the output in XML form.
-- Arguments:
-- ctx VARCHAR2 - The context to operate on.
--
    PROCEDURE RUN (ctx IN VARCHAR2)
    IS
    BEGIN
        CALL DBMS_XMLGEN._CTX_RUN (ctx);
    END;
END
//

