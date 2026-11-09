page 50111 "Bad Customer Card"
{
    PageType = Card;
    SourceTable = Customer;

    layout
    {
        area(Content)
        {
            field(Name; Rec.Name) { }
        }
    }

    actions
    {
        area(Processing)
        {
            action(Rename)
            {
                trigger OnAction()
                begin
                    // Rec.Delete();
                    Rec.Name := 'Renamed';
                    Rec.Modify(true);
                end;
            }
        }
    }
}
