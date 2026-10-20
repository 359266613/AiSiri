$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$checks = 0

function Assert-Project([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Read-Project([string]$RelativePath) {
    return [System.IO.File]::ReadAllText((Join-Path $root $RelativePath))
}

function Read-Plist([string]$RelativePath) {
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create((Join-Path $root $RelativePath), $settings)
    try {
        $document = New-Object System.Xml.XmlDocument
        $document.Load($reader)
        return ,$document
    } finally {
        $reader.Dispose()
    }
}

$plists = @(
    'AiSiri.plist',
    'AiSiriprefs/Resources/AiSiriRoot.plist',
    'AiSiriprefs/Resources/Info.plist',
    'layout/Library/PreferenceLoader/Preferences/AiSiriPrefs.plist'
)
foreach ($relative in $plists) {
    $document = Read-Plist $relative
    Assert-Project ($document.plist.version -eq '1.0') "Invalid plist: $relative"
}

$filter = Read-Plist 'AiSiri.plist'
$bundles = @($filter.SelectNodes('//array/string') | ForEach-Object { $_.InnerText })
Assert-Project ($bundles.Count -eq 2) 'Injection must be limited to two candidate hosts.'
Assert-Project ($bundles -contains 'com.apple.SiriViewService') 'Siri host is missing.'
Assert-Project ($bundles -notcontains 'com.apple.UIKit') 'Global injection is forbidden.'

$makefile = Read-Project 'Makefile'
Assert-Project ($makefile -match 'THEOS_PACKAGE_SCHEME = rootless') 'Rootless must be the default.'
Assert-Project ($makefile -match 'ARCHS = arm64 arm64e') 'Both system process slices are required.'
Assert-Project ((Read-Project 'control') -match 'Package: com.axs.aisiri') 'Wrong package domain.'

$panel = Read-Plist 'AiSiriprefs/Resources/AiSiriRoot.plist'
$defaultKeys = @($panel.SelectNodes("//key[text()='key']/following-sibling::*[1]") |
    ForEach-Object { $_.InnerText })
Assert-Project (($defaultKeys | Sort-Object) -join ',' -eq 'enabled,prefix,reply,speakReply') 'Unexpected settings keys.'
foreach ($key in @('enabled', 'speakReply')) {
    $value = $panel.SelectSingleNode("//dict[key[text()='key']/following-sibling::string[1][text()='$key']]/key[text()='default']/following-sibling::*[1]")
    Assert-Project ($null -ne $value -and $value.Name -eq 'false') "$key must default to false."
}
$entry = Read-Plist 'layout/Library/PreferenceLoader/Preferences/AiSiriPrefs.plist'
$controller = $entry.SelectSingleNode("//key[text()='detail']/following-sibling::*[1]").InnerText
Assert-Project ($controller -eq 'AxsAiSiriRootListController') 'PreferenceLoader controller mismatch.'

$hook = Read-Project 'Hooks/AxsAiSiriSessionHooks.xm'
Assert-Project ($hook -notmatch '%hook\s+(UIApplication|NSObject)') 'Hooks are too broad.'
Assert-Project ($hook -match 'class_getInstanceMethod') 'Runtime method guards are missing.'
Assert-Project ($hook -match '_dyld_register_func_for_add_image') 'Late framework loading must be handled.'
Assert-Project ($hook -match 'speechRecognized:\(id\)recognized\s*\{\s*%orig;') 'Original recognition behavior must be retained.'
Assert-Project ($hook -notmatch '\bcancelRequest\b') 'The probe must not cancel native requests.'
Assert-Project ($hook -match '%group AxsAiSiriReceivedProbe') 'Command reception needs an independent optional hook.'
Assert-Project ($hook -match '%group AxsAiSiriInternalProbe') 'Internal execution needs an independent optional hook.'
Assert-Project ($hook -match '%group AxsAiSiriBatchProbe') 'Batch execution needs an independent optional hook.'
Assert-Project ($hook -match 'turn:nil time:NAN source:@"received-command"') 'Reception must not fabricate execution metadata.'
Assert-Project ($hook -match 'class_getInstanceMethod\(cls, @selector\(_performAceCommand:turnIdentifier:machAbsoluteTime:conflictHandler:\)\)') 'Internal execution must be guarded.'
Assert-Project ($hook -match '%group AxsAiSiriDelegateDispatchProbe') 'Delegate dispatch needs an independent optional hook.'
Assert-Project ($hook -match '#import <substrate.h>') 'The delegate installer must have its declaration before use.'
Assert-Project ($hook -notmatch '\(\s*\^\s*\)\s*\(id\).*block') 'Do not guess the private delegate block ABI.'

$delegateProbe = Read-Project 'Sources/AxsAiSiriDelegateProbe.m'
Assert-Project ($delegateProbe -match 'protocol_copyMethodDescriptionList') 'Delegate signatures must be discovered from runtime protocols.'
Assert-Project ($delegateProbe -match 'signature.methodReturnType, @encode\(void\)') 'Delegate return ABI must be checked.'
Assert-Project ($delegateProbe -match 'getArgumentTypeAtIndex:i\]\[0\] != ''@''') 'Delegate argument ABI must be checked.'
Assert-Project ($delegateProbe -match 'declared && compatible && !installed') 'Only compatible protocol-declared callbacks may be hooked.'
Assert-Project ($delegateProbe -match 'install\(cls, selector, replacement, &original\)') 'Only the observed concrete delegate class may be hooked.'
Assert-Project ($delegateProbe -match 'hooked.count < 24') 'Delegate hook count must be bounded.'
Assert-Project ($delegateProbe -notmatch 'objc_msgSend|NSInvocation|performSelector:') 'Do not invoke private candidates speculatively.'
Assert-Project ($makefile -match 'Sources/AxsAiSiriDelegateProbe.m') 'Delegate probe must be compiled.'
Assert-Project ((Read-Project 'Sources/AxsAiSiriDelegateProbe.h') -match 'FOUNDATION_EXPORT void AxsAiSiriPrepareDelegateProbe') 'Delegate entry point needs C linkage from Logos Objective-C++.'
Assert-Project ($delegateProbe -match 'dlsym\(RTLD_DEFAULT, "_Block_signature"\)') 'Completion ABI must be read through libclosure, not guessed.'
Assert-Project ($delegateProbe -match 'signature.numberOfArguments == 1') 'Zero-argument native completion must be supported.'
Assert-Project ($delegateProbe -match 'signature.numberOfArguments == 2') 'Object-response native completion must be supported.'
Assert-Project ($delegateProbe -notmatch 'struct .*Block|Block_layout') 'Do not hand-parse authenticated block descriptors.'

$manager = Read-Project 'Sources/AxsAiSiriProbeManager.m'
Assert-Project ($manager -match 'if \(!config.enabled\) return;') 'Enabled guard missing.'
Assert-Project ($manager -match 'dispatch_get_main_queue') 'UI submission must be dispatched to main.'
Assert-Project ($manager -match 'state.generation != generation') 'Cross-turn protection missing.'
Assert-Project ($manager -match 'state.preferenceEpoch != self.epoch') 'Preference invalidation missing.'
Assert-Project ($manager -match 'AxsAiSiriSyntheticCommandKey') 'Recursive command guard missing.'
Assert-Project ($manager -notmatch 'NSURLSession|api\.openai\.com|Authorization') 'The local probe must not make model requests.'
Assert-Project ($manager -notmatch '@"transcript"\s*:') 'Diagnostics must not contain transcript text.'
Assert-Project ($manager -match 'state.commandPaths.count < 16') 'Command path diagnostics must be bounded per turn.'
Assert-Project ($manager -match 'if \(!turn \|\| !isfinite\(time\)\) return;') 'Legacy execution must still require real turn and time.'
Assert-Project ($manager -match '@"probe-session-ended"') 'Pending cancellation must be diagnosed.'
Assert-Project ($manager -match 'state.generation != context.generation') 'Delegate callbacks must belong to the same request generation.'
Assert-Project ($manager -match '\[session delegate\] != delegate') 'Only the current session delegate can establish delivery context.'
Assert-Project ($manager -match 'AxsAiSiriIndependentCompletion\(arguments\[1\]\)') 'Do not reuse the native completion.'
Assert-Project ($manager -match 'siriSessionDidReceiveAddViewsCommand:command completion:deliveryCompletion') 'Use the observed addViews delegate route.'
Assert-Project ($manager -match 'context.session = session') 'Native received commands must carry weak session provenance.'
Assert-Project ($manager -notmatch 'mach_absolute_time\(\)|state.turn = NSUUID') 'Do not fabricate turn metadata for delegate delivery.'

$sources = @(
    'Hooks/AxsAiSiriSessionHooks.xm',
    'Headers/AxsAiSiriPrivate.h',
    'Sources/AxsAiSiriConfig.m',
    'Sources/AxsAiSiriDiagnostics.m',
    'Sources/AxsAiSiriProbeManager.m',
    'Sources/AxsAiSiriTrigger.m',
    'Sources/AxsAiSiriDelegateProbe.m',
    'AiSiriprefs/AxsAiSiriRootListController.m'
)
foreach ($relative in $sources) {
    $text = Read-Project $relative
    Assert-Project ($text -notmatch '#(?:import|include)\s+"(?:AF|SA)[^"]+\.h"') "Raw dump imported by $relative"
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root $relative))
    Assert-Project (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) "UTF-8 BOM: $relative"
}

$controllerSource = Read-Project 'AiSiriprefs/AxsAiSiriRootListController.m'
Assert-Project ($controllerSource -notmatch 'self\.table(?:View)?\b') 'Do not call private table accessors during panel loading.'
Assert-Project ($controllerSource -match 'self\.view\.userInteractionEnabled') 'Use the public view for panel loading state.'
Assert-Project ($controllerSource -match 'loadSpecifiersFromPlistName:@"AiSiriRoot"') 'Panel resource name mismatch.'
$info = Read-Plist 'AiSiriprefs/Resources/Info.plist'
$principal = $info.SelectSingleNode("//key[text()='NSPrincipalClass']/following-sibling::*[1]").InnerText
Assert-Project ($principal -eq $controller) 'Bundle principal class and PreferenceLoader entry must agree.'
foreach ($relative in $sources) {
    Assert-Project ((Read-Project $relative) -notmatch '\bAxs(?!AiSiri)[A-Z]') "Generic runtime symbol remains: $relative"
}

Write-Output "PASS: $checks project structure/configuration checks."
Write-Output 'These are static checks, not an Objective-C build or a device test.'
