codeunit 50110 "Bad Codeunit"
{
    procedure NoLoadFields(CustomerNo: Code[20]): Text[100]
    var
        Customer: Record Customer;
        Vendor: Record Vendor;
    begin
        // SetLoadFields on another variable does not count.
        Vendor.SetLoadFields(Name);
        if Customer.Get(CustomerNo) then
            exit(Customer.Name);
    end;

    procedure LoadFieldsAfterRead(): Text[100]
    var
        Customer: Record Customer;
    begin
        // Customer.SetLoadFields(Name);
        Message('Customer.SetLoadFields(Name);');
        /* Customer.SetLoadFields(Name); */
        if Customer.FindFirst() then
            Customer.SetLoadFields(Name);
        exit(Customer.Name);
    end;

    procedure CountWithoutIsolation(): Integer
    var
        SalesLine: Record "Sales Line";
    begin
        // SalesLine.ReadIsolation := IsolationLevel::ReadUncommitted;
        Message('SalesLine.ReadIsolation := IsolationLevel::ReadUncommitted;');
        SalesLine.SetRange("Document Type", SalesLine."Document Type"::Order);
        exit(SalesLine.Count());
    end;

    procedure UncoveredField(CustomerNo: Code[20]): Text
    var
        Customer: Record Customer;
    begin
        Customer.SetLoadFields(Name);
        Customer.Get(CustomerNo);
        exit(Customer.Name +
            Customer.Address);
    end;

    procedure ListDeclared(): Text
    var
        First, Second: Record Customer;
    begin
        First.SetLoadFields(Name);
        if First.FindFirst() then;
        if Second.FindLast() then
            exit(Second.Name);
        exit(First.Name);
    end;

    procedure MultiLineRead(CustomerNo: Code[20])
    var
        Customer: Record Customer;
    begin
        if Customer.Get(
            CustomerNo)
        then
            Message(Customer.Name);
    end;

    procedure SaveAndCommit()
    begin
        // Commit();
        Commit();
    end;

    procedure OldFind()
    var
        Customer: Record Customer;
    begin
        Customer.SetLoadFields(Name);
        if Customer.Find('-') then
            Message(Customer.Name);
    end;

    procedure CalcInLoop()
    var
        Customer: Record Customer;
        Total: Decimal;
    begin
        Customer.SetLoadFields("No.");
        if Customer.FindSet() then
            repeat
                Customer.CalcFields(Balance);
                Total += Customer.Balance;
            until Customer.Next() = 0;
    end;
}
