#
#
#            Nim's Runtime Library
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## A higher level `SQLite`:idx: database wrapper. This interface
## is implemented for other databases too.
##
## Example:
##
## .. code-block:: nim
##
##  import db_sqlite, math
##
##  let theDb = open("mytest.db", nil, nil, nil)
##
##  theDb.exec(sql"Drop table if exists myTestTbl")
##  theDb.exec(sql("""create table myTestTbl (
##       Id    INTEGER PRIMARY KEY,
##       Name  VARCHAR(50) NOT NULL,
##       i     INT(11),
##       f     DECIMAL(18,10))"""))
##
##  theDb.exec(sql"BEGIN")
##  for i in 1..1000:
##    theDb.exec(sql"INSERT INTO myTestTbl (name,i,f) VALUES (?,?,?)",
##          "Item#" & $i, i, sqrt(i.float))
##  theDb.exec(sql"COMMIT")
##
##  for x in theDb.fastRows(sql"select * from myTestTbl"):
##    echo x
##
##  let id = theDb.tryInsertId(sql"INSERT INTO myTestTbl (name,i,f) VALUES (?,?,?)",
##        "Item#1001", 1001, sqrt(1001.0))
##  echo "Inserted item: ", theDb.getValue(sql"SELECT name FROM myTestTbl WHERE id=?", id)
##
##  theDb.close()

import strutils, sqlite3

type
  DbConn* = PSqlite3  ## encapsulates a database connection
  Row* = seq[string]  ## a row of a dataset. NULL database values will be
                       ## transformed always to the empty string.
  InstantRow* = Pstmt  ## a handle that can be used to get a row's column
                       ## text on demand
  EDb* = object of IOError ## exception that is raised if a database error occurs

  SqlQuery* = distinct string ## an SQL query string

  FDb* = object of IOEffect ## effect that denotes a database operation
  FReadDb* = object of FDb   ## effect that denotes a read operation
  FWriteDb* = object of FDb  ## effect that denotes a write operation
{.deprecated: [TRow: Row, TSqlQuery: SqlQuery, TDbConn: DbConn].}

proc sql*(query: string): SqlQuery {.noSideEffect, inline.} =
  ## constructs a SqlQuery from the string `query`. This is supposed to be
  ## used as a raw-string-literal modifier:
  ## ``sql"update user set counter = counter + 1"``
  ##
  ## If assertions are turned off, it does nothing. If assertions are turned
  ## on, later versions will check the string for valid syntax.
  result = SqlQuery(query)

proc dbError(db: DbConn) {.noreturn.} =
  ## raises an EDb exception.
  var e: ref EDb
  new(e)
  e.msg = $sqlite3.errmsg(db)
  raise e

proc dbError*(msg: string) {.noreturn.} =
  ## raises an EDb exception with message `msg`.
  var e: ref EDb
  new(e)
  e.msg = msg
  raise e

proc dbQuote(s: string): string =
  if s.isNil: return "NULL"
  result = "'"
  for c in items(s):
    if c == '\'': add(result, "''")
    else: add(result, c)
  add(result, '\'')

proc dbFormat(formatstr: SqlQuery, args: varargs[string]): string =
  result = ""
  var a = 0
  for c in items(string(formatstr)):
    if c == '?':
      add(result, dbQuote(args[a]))
      inc(a)
    else:
      add(result, c)

proc tryExec*(db: DbConn, query: SqlQuery,
              args: varargs[string, `$`]): bool {.tags: [FReadDb, FWriteDb].} =
  ## tries to execute the query and returns true if successful, false otherwise.
  var q = dbFormat(query, args)
  var stmt: sqlite3.Pstmt
  if prepare_v2(db, q, q.len.cint, stmt, nil) == SQLITE_OK:
    if step(stmt) == SQLITE_DONE:
      result = finalize(stmt) == SQLITE_OK

proc exec*(db: DbConn, query: SqlQuery, args: varargs[string, `$`])  {.
  tags: [FReadDb, FWriteDb].} =
  ## executes the query and raises EDB if not successful.
  if not tryExec(db, query, args): dbError(db)

proc newRow(L: int): Row =
  newSeq(result, L)
  for i in 0..L-1: result[i] = ""

proc setupQuery(db: DbConn, query: SqlQuery,
                args: varargs[string]): Pstmt =
  var q = dbFormat(query, args)
  if prepare_v2(db, q, q.len.cint, result, nil) != SQLITE_OK: dbError(db)

proc setRow(stmt: Pstmt, r: var Row, cols: cint) =
  for col in 0..cols-1:
    setLen(r[col], column_bytes(stmt, col)) # set capacity
    setLen(r[col], 0)
    let x = column_text(stmt, col)
    if not isNil(x): add(r[col], x)

iterator fastRows*(db: DbConn, query: SqlQuery,
                   args: varargs[string, `$`]): Row  {.tags: [FReadDb].} =
  ## Executes the query and iterates over the result dataset.
  ##
  ## This is very fast, but potentially dangerous.  Use this iterator only
  ## if you require **ALL** the rows.
  ##
  ## Breaking the fastRows() iterator during a loop will cause the next
  ## database query to raise an [EDb] exception ``unable to close due to ...``.
  var stmt = setupQuery(db, query, args)
  var L = (column_count(stmt))
  var result = newRow(L)
  while step(stmt) == SQLITE_ROW:
    setRow(stmt, result, L)
    yield result
  if finalize(stmt) != SQLITE_OK: dbError(db)

iterator instantRows*(db: DbConn, query: SqlQuery,
                      args: varargs[string, `$`]): InstantRow
                      {.tags: [FReadDb].} =
  ## same as fastRows but returns a handle that can be used to get column text
  ## on demand using []. Returned handle is valid only within the interator body.
  var stmt = setupQuery(db, query, args)
  while step(stmt) == SQLITE_ROW:
    yield stmt
  if finalize(stmt) != SQLITE_OK: dbError(db)

proc `[]`*(row: InstantRow, col: int32): string {.inline.} =
  ## returns text for given column of the row
  $column_text(row, col)

proc len*(row: InstantRow): int32 {.inline.} =
  ## returns number of columns in the row
  column_count(row)

proc getRow*(db: DbConn, query: SqlQuery,
             args: varargs[string, `$`]): Row {.tags: [FReadDb].} =
  ## retrieves a single row. If the query doesn't return any rows, this proc
  ## will return a Row with empty strings for each column.
  var stmt = setupQuery(db, query, args)
  var L = (column_count(stmt))
  result = newRow(L)
  if step(stmt) == SQLITE_ROW:
    setRow(stmt, result, L)
  if finalize(stmt) != SQLITE_OK: dbError(db)

proc getAllRows*(db: DbConn, query: SqlQuery,
                 args: varargs[string, `$`]): seq[Row] {.tags: [FReadDb].} =
  ## executes the query and returns the whole result dataset.
  result = @[]
  for r in fastRows(db, query, args):
    result.add(r)

iterator rows*(db: DbConn, query: SqlQuery,
               args: varargs[string, `$`]): Row {.tags: [FReadDb].} =
  ## same as `FastRows`, but slower and safe.
  for r in fastRows(db, query, args): yield r

proc getValue*(db: DbConn, query: SqlQuery,
               args: varargs[string, `$`]): string {.tags: [FReadDb].} =
  ## executes the query and returns the first column of the first row of the
  ## result dataset. Returns "" if the dataset contains no rows or the database
  ## value is NULL.
  var stmt = setupQuery(db, query, args)
  if step(stmt) == SQLITE_ROW:
    let cb = column_bytes(stmt, 0)
    if cb == 0:
      result = ""
    else:
      result = newStringOfCap(cb)
      add(result, column_text(stmt, 0))
  else:
    result = ""
  if finalize(stmt) != SQLITE_OK: dbError(db)

proc tryInsertID*(db: DbConn, query: SqlQuery,
                  args: varargs[string, `$`]): int64
                  {.tags: [FWriteDb], raises: [].} =
  ## executes the query (typically "INSERT") and returns the
  ## generated ID for the row or -1 in case of an error.
  var q = dbFormat(query, args)
  var stmt: sqlite3.Pstmt
  result = -1
  if prepare_v2(db, q, q.len.cint, stmt, nil) == SQLITE_OK:
    if step(stmt) == SQLITE_DONE:
      result = last_insert_rowid(db)
    if finalize(stmt) != SQLITE_OK:
      result = -1

proc insertID*(db: DbConn, query: SqlQuery,
               args: varargs[string, `$`]): int64 {.tags: [FWriteDb].} =
  ## executes the query (typically "INSERT") and returns the
  ## generated ID for the row. For Postgre this adds
  ## ``RETURNING id`` to the query, so it only works if your primary key is
  ## named ``id``.
  result = tryInsertID(db, query, args)
  if result < 0: dbError(db)

proc execAffectedRows*(db: DbConn, query: SqlQuery,
                       args: varargs[string, `$`]): int64 {.
                       tags: [FReadDb, FWriteDb].} =
  ## executes the query (typically "UPDATE") and returns the
  ## number of affected rows.
  exec(db, query, args)
  result = changes(db)

proc close*(db: DbConn) {.tags: [FDb].} =
  ## closes the database connection.
  if sqlite3.close(db) != SQLITE_OK: dbError(db)

proc open*(connection, user, password, database: string): DbConn {.
  tags: [FDb].} =
  ## opens a database connection. Raises `EDb` if the connection could not
  ## be established. Only the ``connection`` parameter is used for ``sqlite``.
  var db: DbConn
  if sqlite3.open(connection, db) == SQLITE_OK:
    result = db
  else:
    dbError(db)

proc setEncoding*(connection: DbConn, encoding: string): bool {.
  tags: [FDb].} =
  ## sets the encoding of a database connection, returns true for
  ## success, false for failure.
  ##
  ## Note that the encoding cannot be changed once it's been set.
  ## According to SQLite3 documentation, any attempt to change
  ## the encoding after the database is created will be silently
  ## ignored.
  exec(connection, sql"PRAGMA encoding = ?", [encoding])
  result = connection.getValue(sql"PRAGMA encoding") == encoding

when not defined(testing) and isMainModule:
  var db = open("db.sql", "", "", "")
  exec(db, sql"create table tbl1(one varchar(10), two smallint)", [])
  exec(db, sql"insert into tbl1 values('hello!',10)", [])
  exec(db, sql"insert into tbl1 values('goodbye', 20)", [])
  #db.query("create table tbl1(one varchar(10), two smallint)")
  #db.query("insert into tbl1 values('hello!',10)")
  #db.query("insert into tbl1 values('goodbye', 20)")
  for r in db.rows(sql"select * from tbl1", []):
    echo(r[0], r[1])
  for r in db.instantRows(sql"select * from tbl1", []):
    echo(r[0], r[1])

  db_sqlite.close(db)
