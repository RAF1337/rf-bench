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
        Customer.SetLoadFields("Credit Limit (LCY)");
        Customer.SetRange(Blocked, Customer.Blocked::" ");
        if Customer.FindSet() then
            repeat
                Total += Customer."Credit Limit (LCY)";
            until Customer.Next() = 0;
        exit(Total);
    end;
}
