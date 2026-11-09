#Requires -Version 7.6
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\TestLint.psm1') -Force

    # Writes one AL test codeunit around the given procedure text; returns findings.
    function Get-Findings([string]$Body, [string]$Header = "    Subtype = Test;`n") {
        $dir = Join-Path $TestDrive "t-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory $dir | Out-Null
        $al = "codeunit 70100 `"T`"`n{`n$Header    var`n        Assert: Codeunit `"Library Assert`";`n`n$Body`n}`n"
        Set-Content -LiteralPath (Join-Path $dir 'T.Codeunit.al') -Value $al
        , @(Get-TestLintFindings -TestsDir $dir)
    }
    # Lines 1-6 are the codeunit header, var block and a blank line; [Test] is line 7,
    # the procedure line 8, begin line 9, so the first body line is 10.
    function Test-Proc([string]$Lines) { "    [Test]`n    procedure P()`n    begin`n$Lines`n    end;" }
}

Describe 'Get-TestLintFindings' {
    Context 'no-assertion' {
        It 'flags a [Test] procedure without assertion, at the procedure line' {
            $f = Get-Findings (Test-Proc '        Foo();')
            $f.Count | Should -Be 1
            $f[0].Rule | Should -Be 'no-assertion'
            $f[0].Procedure | Should -Be 'P'
            $f[0].File | Should -Be 'T.Codeunit.al'
            $f[0].Line | Should -Be 8
        }
        It 'passes with LibraryAssert.AreEqual' {
            (Get-Findings (Test-Proc '        LibraryAssert.AreEqual(1, 1, ''x'');')).Count | Should -Be 0
        }
        It 'passes with Assert.IsTrue' {
            (Get-Findings (Test-Proc '        Assert.IsTrue(true, ''x'');')).Count | Should -Be 0
        }
        It 'passes with asserterror' {
            (Get-Findings (Test-Proc '        asserterror Foo();')).Count | Should -Be 0
        }
        It 'passes with Error(' {
            (Get-Findings (Test-Proc '        if X then Error(''bad'');')).Count | Should -Be 0
        }
        It 'ignores a non-[Test] helper without assertions' {
            (Get-Findings "    local procedure Helper()`n    begin`n        Foo();`n    end;").Count | Should -Be 0
        }
        It 'ignores a codeunit without Subtype = Test' {
            (Get-Findings (Test-Proc '        Foo();') -Header '').Count | Should -Be 0
        }
        It 'does not count an assertion in a comment or string' {
            $f = Get-Findings (Test-Proc "        // Assert.AreEqual(1,1,'x');`n        Foo('Assert.IsTrue(');")
            $f.Rule | Should -Be 'no-assertion'
        }
        It 'does not let the next procedure supply the assertion' {
            $body = (Test-Proc '        Foo();') + "`n`n    [Test]`n    procedure Q()`n    begin`n        Assert.IsTrue(true, 'x');`n    end;"
            $f = Get-Findings $body
            $f.Count | Should -Be 1
            $f[0].Procedure | Should -Be 'P'
        }
    }

    Context 'exit-before-assertion' {
        It 'flags exit before the first assertion, at the exit line' {
            $f = Get-Findings (Test-Proc "        if Skip then`n            exit;`n        Assert.IsTrue(true, 'x');")
            $f.Count | Should -Be 1
            $f[0].Rule | Should -Be 'exit-before-assertion'
            $f[0].Line | Should -Be 11
        }
        It 'passes exit after an assertion' {
            (Get-Findings (Test-Proc "        Assert.IsTrue(true, 'x');`n        exit;")).Count | Should -Be 0
        }
        It 'handles nested begin/end blocks in the body' {
            $nested = "        if A then begin`n            repeat`n                Foo();`n            until Next() = 0;`n        end;`n        Assert.IsTrue(true, 'x');"
            (Get-Findings (Test-Proc $nested)).Count | Should -Be 0
            $nested2 = "        if A then begin`n            if B then begin`n                Foo();`n            end;`n        end;`n        exit;`n        Assert.IsTrue(true, 'x');"
            (Get-Findings (Test-Proc $nested2)).Rule | Should -Be 'exit-before-assertion'
        }
        It 'finds an assertion inside a nested block' {
            (Get-Findings (Test-Proc "        if A then begin`n            if B then begin`n                Assert.IsTrue(true, 'x');`n            end;`n        end;")).Count | Should -Be 0
        }
    }

    Context 'nondeterministic' {
        It 'flags <Token>' -ForEach @(
            @{ Token = 'Random(10)'; Code = '        N := Random(10);' }
            @{ Token = 'Randomize()'; Code = '        Randomize();' }
            @{ Token = 'CurrentDateTime'; Code = '        D := CurrentDateTime;' }
            @{ Token = 'Today'; Code = '        D := Today;' }
        ) {
            $f = Get-Findings (Test-Proc "$Code`n        Assert.IsTrue(true, 'x');")
            $f.Count | Should -Be 1
            $f[0].Rule | Should -Be 'nondeterministic'
            $f[0].Procedure | Should -Be 'P'
            $f[0].Line | Should -Be 10
        }
        It 'flags Any.Integer() without a seed' {
            $f = Get-Findings (Test-Proc "        N := Any.Integer();`n        Assert.IsTrue(true, 'x');")
            $f.Rule | Should -Be 'nondeterministic'
        }
        It 'passes Any.Integer() with Any.SetDefaultSeed in the same codeunit' {
            $init = "    local procedure Initialize()`n    begin`n        Any.SetDefaultSeed();`n    end;`n`n"
            (Get-Findings ($init + (Test-Proc "        N := Any.Integer();`n        Assert.IsTrue(true, 'x');"))).Count | Should -Be 0
        }
        It 'passes Any.Integer() with Any.SetSeed' {
            $init = "    local procedure Initialize()`n    begin`n        Any.SetSeed(42);`n    end;`n`n"
            (Get-Findings ($init + (Test-Proc "        N := Any.Integer();`n        Assert.IsTrue(true, 'x');"))).Count | Should -Be 0
        }
        It 'ignores tokens in comments and string literals' {
            $code = "        // Random(1) here`n        /* Today`n           CurrentDateTime */`n        Msg := 'Today and ''Random(1)'' ';`n        Assert.IsTrue(true, 'x');"
            (Get-Findings (Test-Proc $code)).Count | Should -Be 0
        }
        It 'does not flag WorkDate' {
            (Get-Findings (Test-Proc "        D := WorkDate();`n        Assert.IsTrue(true, 'x');")).Count | Should -Be 0
        }
        It 'reports the enclosing procedure for helper usage' {
            $helper = "    local procedure Seed()`n    begin`n        N := Random(5);`n    end;`n`n"
            $f = Get-Findings ($helper + (Test-Proc "        Assert.IsTrue(true, 'x');"))
            $f.Procedure | Should -Be 'Seed'
        }
    }

    It 'returns nothing for a missing folder' {
        @(Get-TestLintFindings -TestsDir (Join-Path $TestDrive 'nope')).Count | Should -Be 0
    }
}
