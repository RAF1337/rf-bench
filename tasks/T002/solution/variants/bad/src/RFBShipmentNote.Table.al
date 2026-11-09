table 50200 "RFB Shipment Note"
{
    Caption = 'Shipment Note';
    DataClassification = CustomerContent;
    LookupPageId = "RFB Shipment Notes";
    DrillDownPageId = "RFB Shipment Notes";

    fields
    {
        field(1; "Entry No."; Integer)
        {
            Caption = 'Entry No.';
            AutoIncrement = true;
            Editable = false;
        }
        field(2; "Customer No."; Code[20])
        {
            Caption = 'Customer No.';
            TableRelation = Customer;
        }
        field(3; Description; Text[250])
        {
            Caption = 'Description';
        }
        field(4; Status; Enum "RFB Shipment Note Status")
        {
            Caption = 'Status';
            Editable = false;
        }
        field(5; "Closed At"; DateTime)
        {
            Caption = 'Closed At';
            Editable = false;
        }
    }

    keys
    {
        key(PK; "Entry No.")
        {
            Clustered = true;
        }
        key(CustomerStatus; "Customer No.", Status)
        {
        }
    }
}
