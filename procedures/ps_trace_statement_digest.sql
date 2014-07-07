/* Copyright (c) 2014, Oracle and/or its affiliates. All rights reserved.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; version 2 of the License.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */

DROP PROCEDURE IF EXISTS ps_trace_statement_digest;

DELIMITER $$

CREATE DEFINER='root'@'localhost' PROCEDURE ps_trace_statement_digest (
        IN in_digest VARCHAR(32),
        IN in_runtime INT, 
        IN in_interval DECIMAL(2,2),
        IN in_start_fresh BOOLEAN,
        IN in_auto_enable BOOLEAN
    )
    COMMENT '
             Description
             -----------

             Traces all instrumentation within Performance Schema for a specific
             Statement Digest. 

             When finding a statement of interest within the 
             performance_schema.events_statements_summary_by_digest table, feed
             the DIGEST MD5 value in to this procedure, set how long to poll for, 
             and at what interval to poll, and it will generate a report of all 
             statistics tracked within Performance Schema for that digest for the
             interval.

             It will also attempt to generate an EXPLAIN for the longest running 
             example of the digest during the interval. Note this may fail, as
             Performance Schema truncates long SQL_TEXT values (and hence the 
             EXPLAIN will fail due to parse errors).

             Requires the SUPER privilege for "SET sql_log_bin = 0;".

             Parameters
             -----------

             in_digest (VARCHAR(32)):
               The statement digest identifier you would like to analyze
             in_runtime (INT):
               The number of seconds to run analysis for (defaults to a minute)
             in_interval (DECIMAL(2,2)):
               The interval (in seconds, may be fractional) at which to try
               and take snapshots (defaults to a second)
             in_start_fresh (BOOLEAN):
               Whether to TRUNCATE the events_statements_history_long and
               events_stages_history_long tables before starting (default false)
             in_auto_enable (BOOLEAN):
               Whether to automatically turn on required consumers (default false)

             Example
             -----------

             mysql> call ps_trace_statement_digest(\'891ec6860f98ba46d89dd20b0c03652c\', 10, 0.1, true, true);
             +--------------------+
             | SUMMARY STATISTICS |
             +--------------------+
             | SUMMARY STATISTICS |
             +--------------------+
             1 row in set (9.11 sec)

             +------------+-----------+-----------+-----------+---------------+------------+------------+
             | executions | exec_time | lock_time | rows_sent | rows_examined | tmp_tables | full_scans |
             +------------+-----------+-----------+-----------+---------------+------------+------------+
             |         21 | 4.11 ms   | 2.00 ms   |         0 |            21 |          0 |          0 |
             +------------+-----------+-----------+-----------+---------------+------------+------------+
             1 row in set (9.11 sec)

             +------------------------------------------+-------+-----------+
             | event_name                               | count | latency   |
             +------------------------------------------+-------+-----------+
             | stage/sql/checking query cache for query |    16 | 724.37 µs |
             | stage/sql/statistics                     |    16 | 546.92 µs |
             | stage/sql/freeing items                  |    18 | 520.11 µs |
             | stage/sql/init                           |    51 | 466.80 µs |
             ...
             | stage/sql/cleaning up                    |    18 | 11.92 µs  |
             | stage/sql/executing                      |    16 | 6.95 µs   |
             +------------------------------------------+-------+-----------+
             17 rows in set (9.12 sec)

             +---------------------------+
             | LONGEST RUNNING STATEMENT |
             +---------------------------+
             | LONGEST RUNNING STATEMENT |
             +---------------------------+
             1 row in set (9.16 sec)
             
             +-----------+-----------+-----------+-----------+---------------+------------+-----------+
             | thread_id | exec_time | lock_time | rows_sent | rows_examined | tmp_tables | full_scan |
             +-----------+-----------+-----------+-----------+---------------+------------+-----------+
             |    166646 | 618.43 µs | 1.00 ms   |         0 |             1 |          0 |         0 |
             +-----------+-----------+-----------+-----------+---------------+------------+-----------+
             1 row in set (9.16 sec)

             // Truncated for clarity...
             +-----------------------------------------------------------------+
             | sql_text                                                        |
             +-----------------------------------------------------------------+
             | select hibeventhe0_.id as id1382_, hibeventhe0_.createdTime ... |
             +-----------------------------------------------------------------+
             1 row in set (9.17 sec)

             +------------------------------------------+-----------+
             | event_name                               | latency   |
             +------------------------------------------+-----------+
             | stage/sql/init                           | 8.61 µs   |
             | stage/sql/Waiting for query cache lock   | 453.23 µs |
             | stage/sql/init                           | 331.07 ns |
             | stage/sql/checking query cache for query | 43.04 µs  |
             ...
             | stage/sql/freeing items                  | 30.46 µs  |
             | stage/sql/cleaning up                    | 662.13 ns |
             +------------------------------------------+-----------+
             18 rows in set (9.23 sec)

             +----+-------------+--------------+-------+---------------+-----------+---------+-------------+------+-------+
             | id | select_type | table        | type  | possible_keys | key       | key_len | ref         | rows | Extra |
             +----+-------------+--------------+-------+---------------+-----------+---------+-------------+------+-------+
             |  1 | SIMPLE      | hibeventhe0_ | const | fixedTime     | fixedTime | 775     | const,const |    1 | NULL  |
             +----+-------------+--------------+-------+---------------+-----------+---------+-------------+------+-------+
             1 row in set (9.27 sec)

             Query OK, 0 rows affected (9.28 sec)
            '
    SQL SECURITY INVOKER
    NOT DETERMINISTIC
    MODIFIES SQL DATA
BEGIN

    DECLARE v_start_fresh BOOLEAN DEFAULT false;
    DECLARE v_auto_enable BOOLEAN DEFAULT false;
    DECLARE v_this_thread_enabed ENUM('YES', 'NO');
    DECLARE v_runtime INT DEFAULT 0;
    DECLARE v_start INT DEFAULT 0;
    DECLARE v_found_stmts INT;

    SET @log_bin := @@sql_log_bin;
    SET sql_log_bin = 0;

    /* Do not track the current thread, it will kill the stack */
    SELECT INSTRUMENTED INTO v_this_thread_enabed FROM performance_schema.threads WHERE PROCESSLIST_ID = CONNECTION_ID();
    CALL sys.ps_setup_disable_thread(CONNECTION_ID());

    DROP TEMPORARY TABLE IF EXISTS stmt_trace;
    CREATE TEMPORARY TABLE stmt_trace (
        thread_id BIGINT,
        timer_start BIGINT,
        event_id BIGINT,
        sql_text longtext,
        timer_wait BIGINT,
        lock_time BIGINT,
        errors BIGINT,
        mysql_errno BIGINT,
        rows_sent BIGINT,
        rows_affected BIGINT,
        rows_examined BIGINT,
        created_tmp_tables BIGINT,
        created_tmp_disk_tables BIGINT,
        no_index_used BIGINT,
        PRIMARY KEY (thread_id, timer_start)
    );

    DROP TEMPORARY TABLE IF EXISTS stmt_stages;
    CREATE TEMPORARY TABLE stmt_stages (
       event_id BIGINT,
       stmt_id BIGINT,
       event_name VARCHAR(128),
       timer_wait BIGINT,
       PRIMARY KEY (event_id)
    );

    SET v_start_fresh = in_start_fresh;
    IF v_start_fresh THEN
        TRUNCATE TABLE performance_schema.events_statements_history_long;
        TRUNCATE TABLE performance_schema.events_stages_history_long;
    END IF;

    SET v_auto_enable = in_auto_enable;
    IF v_auto_enable THEN
        CALL sys.ps_setup_save(0);

        UPDATE performance_schema.threads
           SET INSTRUMENTED = IF(PROCESSLIST_ID IS NOT NULL, 'YES', 'NO');

        -- Only the events_statements_history_long and events_stages_history_long tables and their ancestors are needed
        UPDATE performance_schema.setup_consumers
           SET ENABLED = 'YES'
         WHERE NAME NOT LIKE '%\_history'
               AND NAME NOT LIKE 'events_wait%'
               AND NAME NOT LIKE 'events_transactions%'
               AND NAME <> 'statements_digest';

        UPDATE performance_schema.setup_instruments
           SET ENABLED = 'YES',
               TIMED   = 'YES'
         WHERE NAME LIKE 'statement/%' OR NAME LIKE 'stage/%';
    END IF;

    WHILE v_runtime < in_runtime DO
        SELECT UNIX_TIMESTAMP() INTO v_start;

        INSERT IGNORE INTO stmt_trace
        SELECT thread_id, timer_start, event_id, sql_text, timer_wait, lock_time, errors, mysql_errno, 
               rows_sent, rows_affected, rows_examined, created_tmp_tables, created_tmp_disk_tables, no_index_used
          FROM performance_schema.events_statements_history_long
        WHERE digest = in_digest;

        INSERT IGNORE INTO stmt_stages
        SELECT stages.event_id, stmt_trace.event_id,
               stages.event_name, stages.timer_wait
          FROM performance_schema.events_stages_history_long AS stages
          JOIN stmt_trace ON stages.nesting_event_id = stmt_trace.event_id;

        SELECT SLEEP(in_interval) INTO @sleep;
        SET v_runtime = v_runtime + (UNIX_TIMESTAMP() - v_start);
    END WHILE;

    SELECT "SUMMARY STATISTICS";

    SELECT COUNT(*) executions,
           sys.format_time(SUM(timer_wait)) AS exec_time,
           sys.format_time(SUM(lock_time)) AS lock_time,
           SUM(rows_sent) AS rows_sent,
           SUM(rows_affected) AS rows_affected,
           SUM(rows_examined) AS rows_examined,
           SUM(created_tmp_tables) AS tmp_tables,
           SUM(no_index_used) AS full_scans
      FROM stmt_trace;

    SELECT event_name,
           COUNT(*) as count,
           sys.format_time(SUM(timer_wait)) as latency
      FROM stmt_stages
     GROUP BY event_name
     ORDER BY SUM(timer_wait) DESC;

    SELECT "LONGEST RUNNING STATEMENT";

    SELECT thread_id,
           sys.format_time(timer_wait) AS exec_time,
           sys.format_time(lock_time) AS lock_time,
           rows_sent,
           rows_affected,
           rows_examined,
           created_tmp_tables AS tmp_tables,
           no_index_used AS full_scan
      FROM stmt_trace
     ORDER BY timer_wait DESC LIMIT 1;

    SELECT sql_text
      FROM stmt_trace
     ORDER BY timer_wait DESC LIMIT 1;

    SELECT sql_text, event_id INTO @sql, @sql_id
      FROM stmt_trace
    ORDER BY timer_wait DESC LIMIT 1;

    SELECT event_name,
           sys.format_time(timer_wait) as latency
      FROM stmt_stages
     WHERE stmt_id = @sql_id
     ORDER BY event_id;

    DROP TEMPORARY TABLE stmt_trace;
    DROP TEMPORARY TABLE stmt_stages;

    SET @stmt := CONCAT("EXPLAIN FORMAT=JSON ", @sql);
    PREPARE explain_stmt FROM @stmt;
    EXECUTE explain_stmt;
    DEALLOCATE PREPARE explain_stmt;

    IF v_auto_enable THEN
        CALL sys.ps_setup_reload_saved();
    END IF;
    /* Restore INSTRUMENTED for this thread */
    IF (v_this_thread_enabed = 'YES') THEN
        CALL sys.ps_setup_enable_thread(CONNECTION_ID());
    END IF;

    SET sql_log_bin = @log_bin;
END$$

DELIMITER ;
