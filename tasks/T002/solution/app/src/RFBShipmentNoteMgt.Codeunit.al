codeunit 50200 "RFB Shipment Note Mgt."
{
    /// <summary>
    /// Closes all open shipment notes of a customer and returns how many were closed.
    /// </summary>
    procedure CloseNotesForCustomer(CustomerNo: Code[20]): Integer
    var
        ShipmentNote: Record "RFB Shipment Note";
        ClosedCount: Integer;
    begin
        ShipmentNote.SetRange("Customer No.", CustomerNo);
        ShipmentNote.SetRange(Status, ShipmentNote.Status::Open);
        // Lock the notes that are counted, so the count matches the notes that are closed.
        ShipmentNote.ReadIsolation := IsolationLevel::UpdLock;
        ClosedCount := ShipmentNote.Count();
        if ClosedCount = 0 then
            exit(0);
        ShipmentNote.ModifyAll("Closed At", CurrentDateTime());
        ShipmentNote.ModifyAll(Status, ShipmentNote.Status::Closed);
        exit(ClosedCount);
    end;
}
