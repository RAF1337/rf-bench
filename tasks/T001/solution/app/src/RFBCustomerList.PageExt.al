pageextension 50100 "RFB Customer List" extends "Customer List"
{
    actions
    {
        addlast(processing)
        {
            action("RFB Total Credit Limit")
            {
                ApplicationArea = All;
                Caption = 'Total Credit Limit';
                Image = CreditCard;
                ToolTip = 'Shows the total credit limit (LCY) granted to all customers that are not blocked.';

                trigger OnAction()
                var
                    CreditExposure: Codeunit "RFB Credit Exposure";
                    TotalMsg: Label 'The total credit limit of active customers is %1.', Comment = '%1 = amount in LCY';
                begin
                    Message(TotalMsg, CreditExposure.GetTotalCreditLimit());
                end;
            }
        }
    }
}
