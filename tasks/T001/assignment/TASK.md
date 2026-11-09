# Bug: "Total Credit Limit" includes blocked customers

## Reported by

Credit department (Sales / credit management)

## Problem

The **Customer List** has an action **Total Credit Limit** that shows how much credit we
have granted in total to our active customers. The credit department uses this figure in
the weekly exposure report.

The figure is too high. Customers that are blocked for **Ship** or **Invoice** are still
counted. Only customers that are blocked for **All** are left out today.

A customer that is blocked in any way (Ship, Invoice or All) is not an active customer and
must not count. Only customers whose **Blocked** field is empty count.

## Steps to reproduce

1. Open the Customer List and run **Total Credit Limit**. Note the total.
2. Open a customer that has a credit limit and set **Blocked** to **Ship**.
3. Run **Total Credit Limit** again.

Expected: the total goes down by that customer's credit limit.
Actual: the total does not change.

## Notes

- The total is computed by `GetTotalCreditLimit` in codeunit 50100 "RFB Credit Exposure"
  (`app/src/RFBCreditExposure.Codeunit.al`). Other code calls this procedure, so keep its
  name, signature and return value (the total "Credit Limit (LCY)" in LCY) unchanged.
- With no active customers the total is 0.
- Some of our companies have tens of thousands of customers, and the total is also used in
  scheduled reports, so it must stay fast on large customer tables.
