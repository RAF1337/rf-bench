# AL performance rules

Apply these rules to every AL change in this project.

## Read only the fields you need

- Call `SetLoadFields` before `Get`, `Find`, `FindFirst`, `FindLast` and `FindSet` when the code reads only some fields of the record. List every field the code reads afterwards, also fields passed on to other procedures.
- Do not call `SetLoadFields` on a record that is modified and written back with `Modify`, unless all fields written are loaded.
- Use `IsEmpty` instead of `Find`/`Count` when you only need to know whether records exist.
- Use `CalcSums` instead of looping over records to add up a field.

## Read isolation instead of table locks

- For reads that do not need to block other sessions, set `Rec.ReadIsolation := IsolationLevel::ReadCommitted` (or `ReadUncommitted` for rough counts) instead of relying on the transaction's default isolation.
- Use `IsolationLevel::UpdLock` (or `LockTable`) only right before reading records you will modify in the same transaction.
- Never call `LockTable` on a table you only read.

## No Commit in business logic

- Do not call `Commit` in codeunits, table triggers or event subscribers that implement business logic. The caller owns the transaction.
- If a step must be persisted before a confirmation or a `Codeunit.Run` with error capture, leave the `Commit` decision to the UI layer (page action) and document why.
