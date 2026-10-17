#!/usr/bin/env python3
"""Build real App Intents metadata using the installed Apple toolchain."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
configuration, output = sys.argv[1], Path(sys.argv[2])
# Use the current build's output directory: SwiftPM's native engine and
# Swift Build (Xcode 27 default) store constant values in different layouts.
bin_path = Path(sys.argv[3]).resolve()
if bin_path.parent.name == 'Products':
    objects = bin_path.parent.parent / 'Intermediates.noindex' / 'Pasteboard.build' / configuration.capitalize() / 'Pasteboard-p.build' / 'Objects-normal'
else:
    objects = bin_path / 'PasteMac.build'
values = sorted(objects.rglob('*.swiftconstvalues'))
if not values:
    raise SystemExit('App Intents constant values missing; build with -emit-const-values first.')
source_files = sorted((root / 'Sources' / 'PasteMac').rglob('*.swift'))
toolchain = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()).parent.parent
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
version = subprocess.check_output(['xcodebuild', '-version'], text=True).split('Build version ')[1].strip()
architecture = subprocess.check_output(['uname', '-m'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='pasteboard-appintents-', dir=root / '.build') as temporary:
    source_list = Path(temporary) / 'sources.list'
    value_list = Path(temporary) / 'values.list'
    source_list.write_text('\n'.join(map(str, source_files)) + '\n')
    value_list.write_text('\n'.join(map(str, values)) + '\n')
    subprocess.run(['xcrun', 'appintentsmetadataprocessor', '--output', str(output),
        '--toolchain-dir', str(toolchain), '--module-name', 'PasteMac', '--sdk-root', sdk,
        '--xcode-version', version, '--platform-family', 'macOS', '--deployment-target', '14.0',
        '--target-triple', architecture + '-apple-macos14.0', '--source-file-list', str(source_list),
        '--swift-const-vals-list', str(value_list), '--no-app-shortcuts-localization'], check=True)
metadata = output / 'Metadata.appintents' / 'extract.actionsdata'
if not metadata.is_file() or metadata.stat().st_size == 0:
    raise SystemExit('App Intents extractor did not produce actions metadata.')
print(metadata)
