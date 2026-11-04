# Feature: Shipment notes per customer

## Background

The warehouse keeps notes for upcoming shipments to a customer ("call before delivery",
"deliver to the back door", and so on). Today these notes live in a spreadsheet. We want
them in Business Central, and when a customer's shipments are done the warehouse wants to
close all open notes of that customer in one step.

## What to build

Build a new extension in `app/`. `app/app.json` already exists; keep its id, name,
publisher and version. Use exactly the object names, IDs, field names and types below.
Other code and our reports depend on them.

### Enum 50200 "RFB Shipment Note Status"

| Value | Name   |
| ----- | ------ |
| 0     | Open   |
| 1     | Closed |

### Table 50200 "RFB Shipment Note"

| No. | Field          | Type                            | Notes                                      |
| --- | -------------- | ------------------------------- | ------------------------------------------ |
| 1   | "Entry No."    | Integer                         | Primary key, AutoIncrement                 |
| 2   | "Customer No." | Code[20]                        | Relates to Customer                        |
| 3   | Description    | Text[250]                       |                                            |
| 4   | Status         | Enum "RFB Shipment Note Status" | A new note is Open                         |
| 5   | "Closed At"    | DateTime                        | Empty while open; set when the note closes |

### Page 50200 "RFB Shipment Notes"

A list page over the table that users can find through search. Users add and edit notes
here. Status and "Closed At" are read-only on the page.

The page has an action **Close Open Notes**. It closes all open notes of the customer on the
selected line and tells the user how many notes were closed.

### Codeunit 50200 "RFB Shipment Note Mgt."

```al
procedure CloseNotesForCustomer(CustomerNo: Code[20]): Integer
```

- Closes every open note of the customer: Status becomes Closed and "Closed At" is set to
  the current date and time.
- Returns the number of notes it closed.
- Notes of other customers and notes that are already closed are not changed (an already
  closed note keeps its "Closed At").
- A customer without open notes gives 0.
- Other processes also call this procedure, for example at the end of posting a shipment,
  so it runs inside the caller's transaction.

Also add a permission set for the new objects.
