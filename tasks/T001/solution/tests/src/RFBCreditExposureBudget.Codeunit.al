codeunit 70101 "RFB Credit Exposure Budget"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Assert: Codeunit "Library Assert";
        CustomerCount: Integer;
        // ESTIMATES pending calibration against the container (plan Task 10, step 6): replace
        // with the values measured for the reference solution (solution/app) on the seeded data
        // below. Estimate: one call reads each active customer once. Budget = reference + 20 %,
        // rounded up.
        ReferenceRows: Integer;
        ReferenceStatements: Integer;

    [Test]
    procedure Budget_SumCreditLimit()
    var
        CreditExposure: Codeunit "RFB Credit Exposure";
        RowsBefore: BigInteger;
        StatementsBefore: BigInteger;
        RowsUsed: BigInteger;
        StatementsUsed: BigInteger;
        Total: Decimal;
    begin
        // [GIVEN] 500 customers, half of them blocked
        Initialize();
        SeedCustomers();

        // [WHEN] The total is computed (after one warm-up call for metadata)
        CreditExposure.GetTotalCreditLimit();
        // Drop the session's data cache, so cached reads cannot zero the counters.
        SelectLatestVersion();
        RowsBefore := SessionInformation.SqlRowsRead();
        StatementsBefore := SessionInformation.SqlStatementsExecuted();
        Total := CreditExposure.GetTotalCreditLimit();
        RowsUsed := SessionInformation.SqlRowsRead() - RowsBefore;
        StatementsUsed := SessionInformation.SqlStatementsExecuted() - StatementsBefore;

        // [THEN] The result is right and the SQL cost stays within the budget
        Assert.AreEqual(627500, Total, 'Total credit limit of the 250 active customers.');
        Assert.IsTrue(RowsUsed <= Budget(ReferenceRows),
            StrSubstNo('SQL rows read: %1, budget %2.', RowsUsed, Budget(ReferenceRows)));
        Assert.IsTrue(StatementsUsed <= Budget(ReferenceStatements),
            StrSubstNo('SQL statements executed: %1, budget %2.', StatementsUsed, Budget(ReferenceStatements)));
    end;

    local procedure Initialize()
    begin
        CustomerCount := 500;
        ReferenceRows := 250;
        ReferenceStatements := 2;
    end;

    // Customers RFBB0001..RFBB0500 with credit limit No. * 10. Even numbers are active,
    // odd numbers are blocked for shipping, invoicing or everything in turn.
    // Active total: 10 * (2 + 4 + ... + 500) = 627500.
    local procedure SeedCustomers()
    var
        Customer: Record Customer;
        i: Integer;
    begin
        Customer.DeleteAll();
        for i := 1 to CustomerCount do begin
            Customer.Init();
            Customer."No." := CopyStr(StrSubstNo('RFBB%1', Format(i, 0, '<Integer,4><Filler Character,0>')), 1, MaxStrLen(Customer."No."));
            Customer.Name := Customer."No.";
            Customer."Credit Limit (LCY)" := i * 10;
            if i mod 2 = 0 then
                Customer.Blocked := Customer.Blocked::" "
            else
                case (i div 2) mod 3 of
                    0:
                        Customer.Blocked := Customer.Blocked::Ship;
                    1:
                        Customer.Blocked := Customer.Blocked::Invoice;
                    else
                        Customer.Blocked := Customer.Blocked::All;
                end;
            Customer.Insert(false);
        end;
    end;

    local procedure Budget(Reference: Integer): Integer
    begin
        exit(Round(Reference * 1.2, 1, '>'));
    end;
}
