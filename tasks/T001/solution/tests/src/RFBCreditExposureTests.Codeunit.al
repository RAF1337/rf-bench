codeunit 70100 "RFB Credit Exposure Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Assert: Codeunit "Library Assert";

    [Test]
    procedure BlockedCustomersAreExcluded()
    var
        Customer: Record Customer;
        CreditExposure: Codeunit "RFB Credit Exposure";
    begin
        // [GIVEN] Customers that are not blocked and customers blocked for shipping, invoicing or everything
        Customer.DeleteAll();
        CreateCustomer('RFBT001-A', Customer.Blocked::" ", 1000);
        CreateCustomer('RFBT001-B', Customer.Blocked::Ship, 2000);
        CreateCustomer('RFBT001-C', Customer.Blocked::Invoice, 4000);
        CreateCustomer('RFBT001-D', Customer.Blocked::All, 8000);
        CreateCustomer('RFBT001-E', Customer.Blocked::" ", 16);

        // [WHEN] The total credit limit is computed
        // [THEN] Only the customers that are not blocked count
        Assert.AreEqual(1016, CreditExposure.GetTotalCreditLimit(), 'Total credit limit must only include customers that are not blocked.');
    end;

    [Test]
    procedure NoCustomersGivesZero()
    var
        Customer: Record Customer;
        CreditExposure: Codeunit "RFB Credit Exposure";
    begin
        Customer.DeleteAll();
        Assert.AreEqual(0, CreditExposure.GetTotalCreditLimit(), 'Total credit limit without customers must be 0.');
    end;

    [Test]
    procedure OnlyBlockedCustomersGivesZero()
    var
        Customer: Record Customer;
        CreditExposure: Codeunit "RFB Credit Exposure";
    begin
        Customer.DeleteAll();
        CreateCustomer('RFBT001-F', Customer.Blocked::Ship, 500);
        CreateCustomer('RFBT001-G', Customer.Blocked::All, 700);
        Assert.AreEqual(0, CreditExposure.GetTotalCreditLimit(), 'Total credit limit of blocked customers only must be 0.');
    end;

    [Test]
    procedure ActiveCustomersAreSummed()
    var
        Customer: Record Customer;
        CreditExposure: Codeunit "RFB Credit Exposure";
    begin
        Customer.DeleteAll();
        CreateCustomer('RFBT001-H', Customer.Blocked::" ", 1234.5);
        CreateCustomer('RFBT001-I', Customer.Blocked::" ", 0);
        CreateCustomer('RFBT001-J', Customer.Blocked::" ", 765.5);
        Assert.AreEqual(2000, CreditExposure.GetTotalCreditLimit(), 'Total credit limit must be the sum over all active customers.');
    end;

    local procedure CreateCustomer(CustomerNo: Code[20]; Blocked: Enum "Customer Blocked"; CreditLimit: Decimal)
    var
        Customer: Record Customer;
    begin
        Customer.Init();
        Customer."No." := CustomerNo;
        Customer.Name := CustomerNo;
        Customer.Blocked := Blocked;
        Customer."Credit Limit (LCY)" := CreditLimit;
        Customer.Insert(false);
    end;
}
