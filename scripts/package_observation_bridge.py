#!/usr/bin/env python3
"""Create a local VSIX without installing, changing editor settings or fetching tools."""
import json, pathlib, sys, zipfile
root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'ObservationBridge/vscode'
out = pathlib.Path(sys.argv[1])
if out.exists(): raise SystemExit('Refusing to overwrite package')
manifest = json.loads((source / 'package.json').read_text())
if manifest['contributes']['configuration']['properties']['contextosObservation.enabled']['default'] is not False:
    raise SystemExit('Receiver must remain opt-in')
xml = '''<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
<Metadata><Identity Language="en-US" Id="observation-bridge" Version="0.1.0" Publisher="contextos"/>
<DisplayName>ContextOS Observation Bridge (Local Candidate)</DisplayName>
<Description xml:space="preserve">Local automatic activity estimate with a declared five-minute idle rule.</Description>
<Tags>local</Tags><Categories>Other</Categories>
<Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.95.0"/>
<Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui"/>
<Property Id="Microsoft.VisualStudio.Code.ExecutesCode" Value="true"/></Properties>
</Metadata><Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
<Dependencies/><Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
<Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true"/>
<Asset Type="Microsoft.VisualStudio.Services.Content.License" Path="extension/LICENSE" Addressable="true"/></Assets></PackageManifest>'''
content = '''<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="application/json"/><Default Extension="js" ContentType="application/javascript"/><Default Extension="md" ContentType="text/markdown"/><Default Extension="vsixmanifest" ContentType="text/xml"/><Default Extension="xml" ContentType="text/xml"/><Override PartName="/extension/LICENSE" ContentType="text/plain"/></Types>'''
out.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(out, 'x', zipfile.ZIP_DEFLATED) as z:
    z.writestr('extension.vsixmanifest', xml.replace('Version="0.1.0"', 'Version="'+manifest['version']+'"')); z.writestr('[Content_Types].xml', content)
    for name in ['package.json', 'extension.js', 'protocol.js', 'README.md', 'LICENSE']:
        z.write(source/name, 'extension/'+name)
with zipfile.ZipFile(out) as z:
    assert z.testzip() is None
print(out)
