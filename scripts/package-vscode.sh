#!/bin/sh
# Packages Extensions/vscode into build/lookout-vscode.vsix (a zip with a VSIX manifest).
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*"version": "\(.*\)".*/\1/p' Extensions/vscode/package.json)
STAGE=$(mktemp -d)
mkdir -p "$STAGE/extension"
cp Extensions/vscode/package.json Extensions/vscode/extension.js LICENSE "$STAGE/extension/"
cat > "$STAGE/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="lookout-vscode" Version="$VERSION" Publisher="aslkhon"/>
    <DisplayName>Lookout</DisplayName>
    <Description xml:space="preserve">Lets the Lookout macOS app jump to the exact window and terminal running an agent.</Description>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.75.0"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui"/>
    </Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
XML
cat > "$STAGE/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
  <Default Extension="" ContentType="text/plain"/>
</Types>
XML
mkdir -p build
rm -f build/lookout-vscode.vsix
(cd "$STAGE" && zip -qrX "$OLDPWD/build/lookout-vscode.vsix" "[Content_Types].xml" extension.vsixmanifest extension)
rm -rf "$STAGE"
echo "Built build/lookout-vscode.vsix"
