page 50101 "Good Customer Card"
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
                var
                    GoodCodeunit: Codeunit "Good Codeunit";
                    TempBuffer: Record Customer temporary;
                    Names: List of [Text];
                begin
                    // Rec.Modify(true);
                    Message('Rec.Modify(true);');
                    Names.Insert(1, Rec.Name);
                    TempBuffer := Rec;
                    TempBuffer.Insert();
                    GoodCodeunit.UpdateName(Rec, 'Renamed');
                    CurrPage.Update(false);
                end;
            }
        }
    }
}
