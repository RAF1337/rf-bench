codeunit 50112 "Bad Extra Codeunit"
{
    var
        Customer: Record Customer;
        SalesLine: Record "Sales Line";

    procedure PrepareGlobals()
    begin
        // Applies to these globals, but only inside this procedure.
        Customer.SetLoadFields(Name);
        SalesLine.ReadIsolation := IsolationLevel::ReadCommitted;
    end;

    procedure ReadGlobal(CustomerNo: Code[20]): Text[100]
    begin
        if Customer.Get(CustomerNo) then
            exit(Customer.Name);
    end;

    procedure CountGlobal(): Integer
    begin
        exit(SalesLine.Count());
    end;

    procedure EmptyLoadFields(VendorNo: Code[20]): Text[100]
    var
        Vendor: Record Vendor;
    begin
        Vendor.SetLoadFields();
        if Vendor.Get(VendorNo) then
            exit(Vendor.Name);
    end;
}
