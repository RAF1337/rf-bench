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
        // Planted: Count without ReadIsolation and an explicit Commit.
        ShipmentNote.SetRange("Customer No.", CustomerNo);
        ShipmentNote.SetRange(Status, ShipmentNote.Status::Open);
        ClosedCount := ShipmentNote.Count();
        if ClosedCount = 0 then
            exit(0);
        ShipmentNote.ModifyAll("Closed At", CurrentDateTime());
        ShipmentNote.ModifyAll(Status, ShipmentNote.Status::Closed);
        Commit();
        exit(ClosedCount);
    end;
}
