codeunit 50200 "RFB Shipment Note Mgt."
{
    /// <summary>
    /// Closes all open shipment notes of a customer and returns how many were closed.
    /// </summary>
    procedure CloseNotesForCustomer(CustomerNo: Code[20]): Integer
    var
        ShipmentNote: Record "RFB Shipment Note";
        NoteToClose: Record "RFB Shipment Note";
        ClosedAt: DateTime;
        ClosedCount: Integer;
    begin
        ClosedAt := CurrentDateTime();
        ShipmentNote.SetRange("Customer No.", CustomerNo);
        ShipmentNote.SetRange(Status, ShipmentNote.Status::Open);
        if ShipmentNote.FindSet(true) then
            repeat
                NoteToClose := ShipmentNote;
                NoteToClose.Status := NoteToClose.Status::Closed;
                NoteToClose."Closed At" := ClosedAt;
                NoteToClose.Modify(true);
                ClosedCount += 1;
            until ShipmentNote.Next() = 0;
        exit(ClosedCount);
    end;
}
