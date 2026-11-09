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
        // Functionally fixed, but reads full rows and uses Find('-').
        Customer.SetRange(Blocked, Customer.Blocked::" ");
        if Customer.Find('-') then
            repeat
                Total += Customer."Credit Limit (LCY)";
            until Customer.Next() = 0;
        exit(Total);
    end;
}
