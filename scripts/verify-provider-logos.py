#!/usr/bin/env python3
"""Check complete provider asset coverage, source provenance and shipped bytes offline."""
import hashlib
import json
import pathlib
import re
import struct
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'Brand/ProviderLogos.xcassets'
source = (ROOT / 'Packages/MosaicCore/Sources/MosaicCore/Providers/ProviderCatalog.swift').read_text()
expected = set(re.findall(r'logoAssetName: "(ProviderLogo[^"\n]+)"', source)) - {'ProviderLogoCustom'}
manifest = json.loads((ROOT / 'Brand/ProviderLogoSources.json').read_text())
entries = manifest['logos']
assert {entry['asset'] for entry in entries} == expected, 'Provider/source coverage mismatch'
assert {p.stem for p in CATALOG.glob('*.imageset')} == expected, 'Provider/asset coverage mismatch'
listed_files = {entry['file'] for entry in entries}
assert len(listed_files) == len(entries), 'Duplicate source records'
for entry in entries:
    assert entry['sourcePage'].startswith('https://') and entry['sourceURL'].startswith('https://')
    file = CATALOG / entry['file']
    assert hashlib.sha256(file.read_bytes()).hexdigest() == entry['sha256'], f'Changed asset: {file}'
for asset in sorted(expected):
    folder = CATALOG / f'{asset}.imageset'
    images = json.loads((folder / 'Contents.json').read_text())['images']
    assert any('appearances' not in image for image in images), f'Missing default variant: {asset}'
    for image in images:
        file = folder / image['filename']
        assert str(file.relative_to(CATALOG)) in listed_files, f'Missing provenance: {file}'
        if file.suffix == '.png':
            data = file.read_bytes()
            assert data[:8] == b'\x89PNG\r\n\x1a\n'
            assert struct.unpack('>II', data[16:24]) == (256, 256), f'Unexpected canvas: {file}'
        elif file.suffix == '.svg':
            tree = ET.parse(file)
            assert tree.getroot().tag.endswith('svg')
            assert not any(element.tag.endswith('script') for element in tree.iter())
            for element in tree.iter():
                for key, value in element.attrib.items():
                    if key.endswith('href'):
                        assert value.startswith('#'), f'External SVG dependency: {file}'
        else:
            raise AssertionError(f'Unsupported artwork: {file}')
print(f'PASS: {len(expected)} providers, {len(entries)} local logo variants, source hashes and image formats')
