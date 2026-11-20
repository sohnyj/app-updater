@{
    ExcludeRules = @(
        # Colored console output is the intended user interface.
        'PSAvoidUsingWriteHost',
        # Internal script functions; -WhatIf and -Confirm are not offered.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules        = @{
        # Formatting: CodeFormattingOTBS preset
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            IndentationSize     = 4
        }

        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }

        PSUseCorrectCasing         = @{
            Enable = $true
        }

        # Compatibility: PowerShell 7.6 on Windows
        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @('7.6')
        }

        # No 7.6 profile ships with PSScriptAnalyzer; 7.0 is the newest Windows profile.
        PSUseCompatibleCommands    = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core')
        }
    }
}
