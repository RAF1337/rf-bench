codeunit 50100 "RFB Credit Exposure"
{
    /// <summary>
    /// Returns the sum of "Credit Limit (LCY)" over all customers that are not blocked.
    /// </summary>
    procedure GetTotalCreditLimit(): Decimal
    var
        Customer: Record Customer;
    begin
        // The sum is computed by SQL; no customer rows are fetched.
        Customer.SetRange(Blocked, Customer.Blocked::" ");
        Customer.CalcSums("Credit Limit (LCY)");
        exit(Customer."Credit Limit (LCY)");
    end;
}
