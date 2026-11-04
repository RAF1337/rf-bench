permissionset 50200 "RFB Shipment Notes"
{
    Assignable = true;
    Caption = 'Shipment Notes';
    Permissions =
        tabledata "RFB Shipment Note" = RIMD,
        table "RFB Shipment Note" = X,
        page "RFB Shipment Notes" = X,
        codeunit "RFB Shipment Note Mgt." = X;
}
