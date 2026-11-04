page 50102 "Good Customer Buffer"
{
    PageType = List;
    SourceTable = Customer;
    SourceTableTemporary = true;

    layout
    {
        area(Content)
        {
            repeater(Lines)
            {
                field(Name; Rec.Name) { }
            }
        }
    }

    trigger OnOpenPage()
    begin
        Rec.Init();
        Rec."No." := 'A';
        Rec.Insert();
    end;
}
