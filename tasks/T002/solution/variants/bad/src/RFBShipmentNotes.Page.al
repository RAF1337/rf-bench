page 50200 "RFB Shipment Notes"
{
    ApplicationArea = All;
    Caption = 'Shipment Notes';
    PageType = List;
    SourceTable = "RFB Shipment Note";
    UsageCategory = Lists;

    layout
    {
        area(Content)
        {
            repeater(Notes)
            {
                field("Entry No."; Rec."Entry No.")
                {
                    ToolTip = 'Specifies the number of the note. It is assigned automatically.';
                }
                field("Customer No."; Rec."Customer No.")
                {
                    ToolTip = 'Specifies the customer that the note is for.';
                }
                field(Description; Rec.Description)
                {
                    ToolTip = 'Specifies the note for the shipment.';
                }
                field(Status; Rec.Status)
                {
                    ToolTip = 'Specifies whether the note is open or closed.';
                }
                field("Closed At"; Rec."Closed At")
                {
                    ToolTip = 'Specifies when the note was closed.';
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(CloseOpenNotes)
            {
                Caption = 'Close Open Notes';
                Image = Close;
                ToolTip = 'Closes all open notes of the customer on the selected line.';

                trigger OnAction()
                var
                    ShipmentNote: Record "RFB Shipment Note";
                    ClosedMsg: Label 'Open notes closed for customer %1.', Comment = '%1 = customer number';
                begin
                    // Planted: closes the notes directly from the page.
                    ShipmentNote.SetRange("Customer No.", Rec."Customer No.");
                    ShipmentNote.SetRange(Status, ShipmentNote.Status::Open);
                    ShipmentNote.ModifyAll("Closed At", CurrentDateTime());
                    ShipmentNote.ModifyAll(Status, ShipmentNote.Status::Closed);
                    Message(ClosedMsg, Rec."Customer No.");
                    CurrPage.Update(false);
                end;
            }
        }
        area(Promoted)
        {
            actionref(CloseOpenNotes_Promoted; CloseOpenNotes)
            {
            }
        }
    }
}
