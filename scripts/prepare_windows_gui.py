#!/usr/bin/env python3
"""Generate GUI identity from a compiled, verified Swift contract; no installs."""
import argparse
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    contract = json.loads(args.contract.read_text(encoding="utf-8"))
    version = contract["version"]
    source = (root / "Sources/ContextOSCore/Model/ContextOSVersion.swift").read_text(encoding="utf-8")
    current = re.search(r'public static let current\s*=\s*"([0-9.]+)"', source)
    if not (re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) and current and version == current[1]
            and contract["schema_version"] == 1 and {"contract", "doctor"} <= set(contract["cli_commands"])):
        raise ValueError("Compiled Swift contract and source identity do not match")
    generated = root / "Windows/ContextOS.Windows/obj"
    generated.mkdir(parents=True, exist_ok=True)
    project = ET.Element("Project")
    properties = ET.SubElement(project, "PropertyGroup")
    for name, value in {"Version": version, "AssemblyVersion": version + ".0", "FileVersion": version + ".0",
                        "InformationalVersion": version, "IncludeSourceRevisionInInformationalVersion": "false"}.items():
        ET.SubElement(properties, name).text = value
    ET.indent(project)
    (generated / "CoreVersion.props").write_bytes(ET.tostring(project, encoding="utf-8", xml_declaration=True) + b"\n")
    (generated / "CoreContract.json").write_text(json.dumps(contract, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"version": version, "contract_generated": True, "windows_runtime_verified": False}))


if __name__ == "__main__":
    main()
