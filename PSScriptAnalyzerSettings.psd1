@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Ferramenta de linha de comando: o console colorido é a interface.
        'PSAvoidUsingWriteHost',
        # As alterações passam pelo diário (DryRun e undo) em vez de ShouldProcess em cada função.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
