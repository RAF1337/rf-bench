codeunit 70200 "RFB Shipment Note Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Assert: Codeunit "Library Assert";
        CustomerATok: Label 'RFBT002-A', Locked = true;
        CustomerBTok: Label 'RFBT002-B', Locked = true;

    [Test]
    procedure ClosesOpenNotesOfCustomerAndReturnsCount()
    var
        ShipmentNote: Record "RFB Shipment Note";
        ShipmentNoteMgt: Codeunit "RFB Shipment Note Mgt.";
    begin
        // [GIVEN] Three open notes for customer A
        Initialize();
        CreateNote(CustomerATok, ShipmentNote.Status::Open, 0DT);
        CreateNote(CustomerATok, ShipmentNote.Status::Open, 0DT);
        CreateNote(CustomerATok, ShipmentNote.Status::Open, 0DT);

        // [WHEN] The notes of customer A are closed
        // [THEN] Three notes are closed, all with a closing time
        Assert.AreEqual(3, ShipmentNoteMgt.CloseNotesForCustomer(CustomerATok), 'Number of closed notes.');
        ShipmentNote.SetRange("Customer No.", CustomerATok);
        ShipmentNote.SetRange(Status, ShipmentNote.Status::Open);
        Assert.IsTrue(ShipmentNote.IsEmpty(), 'No open notes may remain for the customer.');
        ShipmentNote.SetRange(Status, ShipmentNote.Status::Closed);
        ShipmentNote.SetRange("Closed At", 0DT);
        Assert.IsTrue(ShipmentNote.IsEmpty(), 'Every closed note must have Closed At set.');
        ShipmentNote.SetRange("Closed At");
        Assert.AreEqual(3, ShipmentNote.Count(), 'Number of closed notes in the table.');
    end;

    [Test]
    procedure LeavesOtherCustomersUntouched()
    var
        ShipmentNote: Record "RFB Shipment Note";
        ShipmentNoteMgt: Codeunit "RFB Shipment Note Mgt.";
    begin
        // [GIVEN] Open notes for customers A and B
        Initialize();
        CreateNote(CustomerATok, ShipmentNote.Status::Open, 0DT);
        CreateNote(CustomerBTok, ShipmentNote.Status::Open, 0DT);
        CreateNote(CustomerBTok, ShipmentNote.Status::Open, 0DT);

        // [WHEN] The notes of customer A are closed
        Assert.AreEqual(1, ShipmentNoteMgt.CloseNotesForCustomer(CustomerATok), 'Number of closed notes.');

        // [THEN] The notes of customer B are still open and have no closing time
        ShipmentNote.SetRange("Customer No.", CustomerBTok);
        ShipmentNote.SetRange(Status, ShipmentNote.Status::Open);
        Assert.AreEqual(2, ShipmentNote.Count(), 'Notes of another customer must stay open.');
        ShipmentNote.SetFilter("Closed At", '<>%1', 0DT);
        Assert.IsTrue(ShipmentNote.IsEmpty(), 'Notes of another customer must not get a closing time.');
    end;

    [Test]
    procedure AlreadyClosedNotesAreNotCountedOrChanged()
    var
        ShipmentNote: Record "RFB Shipment Note";
        ShipmentNoteMgt: Codeunit "RFB Shipment Note Mgt.";
        EarlierClose: DateTime;
        ClosedEntryNo: Integer;
    begin
        // [GIVEN] Customer A has one note closed earlier and two open notes
        Initialize();
        EarlierClose := CreateDateTime(DMY2Date(1, 3, 2025), 100000T);
        ClosedEntryNo := CreateNote(CustomerATok, ShipmentNote.Status::Closed, EarlierClose);
        CreateNote(CustomerATok, ShipmentNote.Status::Open, 0DT);
        CreateNote(CustomerATok, ShipmentNote.Status::Open, 0DT);

        // [WHEN] The notes of customer A are closed
        // [THEN] Only the two open notes count, and the earlier closing time is kept
        Assert.AreEqual(2, ShipmentNoteMgt.CloseNotesForCustomer(CustomerATok), 'Only open notes may be counted.');
        ShipmentNote.Get(ClosedEntryNo);
        Assert.AreEqual(EarlierClose, ShipmentNote."Closed At", 'A note that was already closed must keep its closing time.');
    end;

    [Test]
    procedure NoOpenNotesReturnsZero()
    var
        ShipmentNote: Record "RFB Shipment Note";
        ShipmentNoteMgt: Codeunit "RFB Shipment Note Mgt.";
    begin
        Initialize();
        CreateNote(CustomerBTok, ShipmentNote.Status::Open, 0DT);
        Assert.AreEqual(0, ShipmentNoteMgt.CloseNotesForCustomer(CustomerATok), 'A customer without notes has nothing to close.');
        CreateNote(CustomerATok, ShipmentNote.Status::Closed, CurrentDateTime());
        Assert.AreEqual(0, ShipmentNoteMgt.CloseNotesForCustomer(CustomerATok), 'A customer with only closed notes has nothing to close.');
    end;

    [Test]
    procedure SecondCallClosesNothing()
    var
        ShipmentNote: Record "RFB Shipment Note";
        ShipmentNoteMgt: Codeunit "RFB Shipment Note Mgt.";
    begin
        Initialize();
        CreateNote(CustomerATok, ShipmentNote.Status::Open, 0DT);
        CreateNote(CustomerATok, ShipmentNote.Status::Open, 0DT);
        Assert.AreEqual(2, ShipmentNoteMgt.CloseNotesForCustomer(CustomerATok), 'First call closes the open notes.');
        Assert.AreEqual(0, ShipmentNoteMgt.CloseNotesForCustomer(CustomerATok), 'Second call has nothing left to close.');
    end;

    [Test]
    procedure NewNoteIsOpen()
    var
        ShipmentNote: Record "RFB Shipment Note";
    begin
        Initialize();
        ShipmentNote.Init();
        ShipmentNote."Customer No." := CustomerATok;
        ShipmentNote.Description := 'Deliver to the back door';
        ShipmentNote.Insert(true);
        ShipmentNote.Get(ShipmentNote."Entry No.");
        Assert.AreEqual(ShipmentNote.Status::Open, ShipmentNote.Status, 'A new note is open.');
        Assert.AreEqual(0DT, ShipmentNote."Closed At", 'A new note has no closing time.');
    end;

    local procedure Initialize()
    var
        ShipmentNote: Record "RFB Shipment Note";
    begin
        ShipmentNote.DeleteAll();
    end;

    local procedure CreateNote(CustomerNo: Code[20]; Status: Enum "RFB Shipment Note Status"; ClosedAt: DateTime): Integer
    var
        ShipmentNote: Record "RFB Shipment Note";
    begin
        ShipmentNote.Init();
        ShipmentNote."Customer No." := CustomerNo;
        ShipmentNote.Description := CopyStr(StrSubstNo('Note for %1', CustomerNo), 1, MaxStrLen(ShipmentNote.Description));
        ShipmentNote.Status := Status;
        ShipmentNote."Closed At" := ClosedAt;
        ShipmentNote.Insert(true);
        exit(ShipmentNote."Entry No.");
    end;
}
