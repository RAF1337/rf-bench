codeunit 50100 "Good Codeunit"
{
    var
        GlobalCustomer: Record Customer;

    procedure GetCustomerName(CustomerNo: Code[20]): Text[100]
    var
        Customer: Record Customer;
    begin
        Customer.SetLoadFields(Name);
        if Customer.Get(CustomerNo) then
            exit(Customer.Name);
    end;

    procedure MultiLineAndList(CustomerNo: Code[20]): Text
    var
        Customer, Customer2: Record Customer;
    begin
        Customer.SetLoadFields(
            Name,
            "Name 2");
        customer2.SetLoadFields(Address);
        if Customer.Get(
            CustomerNo)
        then
            exit(Customer.Name + Customer."Name 2" + Customer."No.");
        if CUSTOMER2.FindFirst() then
            exit(Customer2.Address + Format(Customer2.SystemId));
    end;

    procedure CountWithIsolation(): Integer
    var
        SalesLine: Record "Sales Line";
    begin
        SalesLine.ReadIsolation := IsolationLevel::ReadUncommitted;
        SalesLine.SetRange("Document Type", SalesLine."Document Type"::Order);
        if SalesLine.IsEmpty() then
            exit(0);
        exit(SalesLine.Count());
    end;

    procedure CommentsAndStrings()
    var
        Customer: Record Customer;
    begin
        // Customer.FindFirst(); Commit(); Customer.Find('-');
        /* Customer.Get('X'); Customer.Count(); Customer.CalcFields(Balance); */
        Message('Customer.FindSet(); Commit(); Customer.Find(''-''); Customer.IsEmpty()');
    end;

    procedure CalcAfterLoop(): Decimal
    var
        Customer: Record Customer;
        Names: List of [Text];
        CustomerName: Text;
    begin
        Customer.SetLoadFields(Name);
        if Customer.FindSet() then
            repeat
                Names.Add(Customer.Name);
            until Customer.Next() = 0;
        foreach CustomerName in Names do
            Message(CustomerName);
        Customer.CalcFields(Balance);
        exit(Customer.Balance);
    end;

    procedure AutoCalcInLoop(): Decimal
    var
        Customer: Record Customer;
        Total: Decimal;
    begin
        Customer.SetLoadFields("No.");
        Customer.SetAutoCalcFields(Balance);
        if Customer.FindSet() then
            repeat
                Total += Customer.Balance;
            until Customer.Next() = 0;
        exit(Total);
    end;

    procedure ModernFind(): Boolean
    var
        Customer: Record Customer;
    begin
        Customer.SetLoadFields(Name);
        if Customer.Find() then
            Customer."Name 2" := 'Changed';
        exit(Customer.Find('>'));
    end;

    procedure TemporaryAndGlobal(var TempCustomer: Record Customer temporary): Integer
    var
        TempBuffer: Record Customer temporary;
    begin
        if TempBuffer.Get('X') then
            exit(TempBuffer.Count());
        if GlobalCustomer.Get('X') then
            exit(1);
        if TempCustomer.FindFirst() then
            exit(TempCustomer.Count());
    end;

    procedure UpdateName(var Customer: Record Customer; NewName: Text[100])
    begin
        Customer.Name := NewName;
        Customer.Modify(true);
    end;
}
