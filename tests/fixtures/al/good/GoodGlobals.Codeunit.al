codeunit 50103 "Good Globals Codeunit"
{
    var
        Customer: Record Customer;
        SalesLine: Record "Sales Line";

    procedure ReadGlobal(CustomerNo: Code[20]): Text[100]
    begin
        Customer.SetLoadFields(Name);
        if Customer.Get(CustomerNo) then
            exit(Customer.Name);
    end;

    procedure CountGlobal(): Integer
    begin
        SalesLine.ReadIsolation := IsolationLevel::ReadCommitted;
        exit(SalesLine.Count());
    end;

    procedure ShadowedGlobal(): Boolean
    var
        Customer: Record Customer temporary;
    begin
        // The local temporary record hides the global one.
        exit(Customer.Get('X'));
    end;

    procedure RecordParameter(Vendor: Record Vendor): Boolean
    begin
        // Parameters may be prepared by the caller; they are not sites.
        exit(Vendor.Get(Vendor."No."));
    end;
}
