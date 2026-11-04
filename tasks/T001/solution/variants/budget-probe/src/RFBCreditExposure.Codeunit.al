codeunit 50100 "RFB Credit Exposure"
{
    /// <summary>
    /// Returns the sum of "Credit Limit (LCY)" over all customers that are not blocked.
    /// </summary>
    procedure GetTotalCreditLimit(): Decimal
    var
        Customer: Record Customer;
        Total: Decimal;
    begin
        // Budget probe: functionally right, but reads every customer (full rows) and filters
        // Blocked in AL instead of in SQL. Budget_SumCreditLimit must fail on this.
        if Customer.FindSet() then
            repeat
                if Customer.Blocked = Customer.Blocked::" " then
                    Total += Customer."Credit Limit (LCY)";
            until Customer.Next() = 0;
        exit(Total);
    end;
}
