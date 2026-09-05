#!/usr/bin/env python3
"""Build a signed App Store IPA; upload only when explicitly requested."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build' / 'app-store'
BUNDLE_ID = 'com.niki.xxread'


class BuildError(Exception):
    pass


def version_from_pubspec():
    match = re.search(r'^version:\s*([^+\s]+)', (ROOT / 'pubspec.yaml').read_text(), re.M)
    if not match:
        raise BuildError('pubspec.yaml has no version')
    return match[1]


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument('--build-name', default=None)
    result.add_argument('--build-number', required=True)
    result.add_argument('--check', action='store_true', help='Read-only local prerequisite check')
    result.add_argument('--upload', action='store_true', help='Upload archive to App Store Connect')
    result.add_argument('--allow-beta-xcode', action='store_true', help='Local export/check only')
    return result


def read_command(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        raise BuildError('Unable to inspect local Xcode/SDK installation') from None


def check_inputs(args):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.build_name):
        raise BuildError('--build-name must use major.minor.patch')
    if not re.fullmatch(r'[1-9][0-9]*(?:\.[0-9]+){0,2}', args.build_number):
        raise BuildError('--build-number must use 1-3 numeric components; first must be positive')
    if args.upload and args.allow_beta_xcode:
        raise BuildError('--allow-beta-xcode cannot be used with --upload')
    if not os.environ.get('IOS_TEAM_ID', '').strip():
        raise BuildError('IOS_TEAM_ID is required for automatic signing')
    credentials = [os.environ.get(name, '').strip() for name in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH')]
    if any(credentials) and not all(credentials):
        raise BuildError('ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH must be provided together')
    if args.upload and not all(credentials):
        raise BuildError('ASC API credentials are required for --upload')
    if all(credentials):
        key = Path(credentials[2])
        if not key.is_absolute() or not key.is_file():
            raise BuildError('ASC_KEY_PATH must be an existing absolute private-key path')
        if ROOT.resolve() == key.resolve() or ROOT.resolve() in key.resolve().parents:
            raise BuildError('Store the ASC private key outside the repository')
        if key.stat().st_mode & 0o077:
            raise BuildError('ASC private key permissions must exclude group/other access (chmod 600)')
    for command in ('flutter', 'pod', 'xcodebuild', 'xcrun', 'codesign'):
        if shutil.which(command) is None:
            raise BuildError(f'Required tool is missing: {command}')
    if not (ROOT / 'ios/Runner.xcworkspace').is_dir():
        raise BuildError('ios/Runner.xcworkspace is missing')
    xcode = read_command(['xcodebuild', '-version'])
    match = re.search(r'Xcode (\d+)', xcode)
    if not match or int(match[1]) < 26:
        raise BuildError('Xcode 26 or newer is required')
    developer_dir = os.environ.get('DEVELOPER_DIR') or read_command(['xcode-select', '-p'])
    # Seed builds often omit "Beta" from xcodebuild -version, but have a
    # lowercase suffix in ProductBuildVersion and/or a beta app path.
    seed = re.search(r'beta|seed|release.?candidate', developer_dir + '\n' + xcode, re.I)
    seed = seed or re.search(r'Build version\s+\S+[a-z]\b', xcode)
    if seed and not args.allow_beta_xcode:
        raise BuildError('Selected Xcode is a beta/seed; select a released Xcode for upload')
    sdk = read_command(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'])
    if not re.match(r'^\d+', sdk) or int(sdk.split('.')[0]) < 26:
        raise BuildError('iPhoneOS SDK 26 or newer is required')


def auth_arguments():
    args = ['-allowProvisioningUpdates']
    if os.environ.get('ASC_KEY_PATH'):
        args += ['-authenticationKeyPath', os.environ['ASC_KEY_PATH'],
                 '-authenticationKeyID', os.environ['ASC_KEY_ID'],
                 '-authenticationKeyIssuerID', os.environ['ASC_ISSUER_ID']]
    return args


def run_step(label, command, log, cwd=ROOT):
    print(label, flush=True)
    # Xcode can echo operational identifiers. Keep its output in a private,
    # ignored log; never echo the command or CalledProcessError to the user.
    with log.open('a') as stream:
        stream.write('\n' + label + '\n')
        stream.flush()
        try:
            subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, check=True)
        except (OSError, subprocess.CalledProcessError):
            raise BuildError(f'{label} failed; inspect private log: {log}') from None


def validate_archive(archive, version, build):
    apps = list((archive / 'Products/Applications').glob('*.app'))
    if len(apps) != 1:
        raise BuildError('Archive must contain exactly one application')
    app = apps[0]
    try:
        with (app / 'Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        with (app / 'PrivacyInfo.xcprivacy').open('rb') as stream:
            privacy = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise BuildError('Archive is missing valid Info.plist or PrivacyInfo.xcprivacy') from None
    expected = {'CFBundleIdentifier': BUNDLE_ID, 'CFBundleShortVersionString': version,
                'CFBundleVersion': build, 'ITSAppUsesNonExemptEncryption': False}
    if any(info.get(key) != value for key, value in expected.items()):
        raise BuildError('Archive bundle/version/build/encryption does not match requested identity')
    reasons = {entry.get('NSPrivacyAccessedAPIType'): entry.get('NSPrivacyAccessedAPITypeReasons', [])
               for entry in privacy.get('NSPrivacyAccessedAPITypes', [])}
    if 'CA92.1' not in reasons.get('NSPrivacyAccessedAPICategoryUserDefaults', []):
        raise BuildError('Archive must declare app-local UserDefaults access')
    if not (app / '_CodeSignature/CodeResources').is_file() or not (app / 'embedded.mobileprovision').is_file():
        raise BuildError('Archive is unsigned or missing provisioning profile')
    return app


def export_options(upload):
    return {'method': 'app-store-connect', 'destination': 'upload' if upload else 'export',
            'signingStyle': 'automatic', 'teamID': os.environ['IOS_TEAM_ID'],
            'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True,
            'iCloudContainerEnvironment': 'Production', 'testFlightInternalTestingOnly': False}


def execute(args):
    args.build_name = args.build_name or version_from_pubspec()
    check_inputs(args)
    output = OUT / f'{args.build_name}-{args.build_number}'
    if output.exists():
        raise BuildError(f'Output exists; refusing overwrite: {output}')
    if args.check:
        print('Local prerequisites passed. Apple account, signing assets and upload acceptance are not verified.')
        return 0
    output.mkdir(parents=True, mode=0o700)
    os.chmod(output, 0o700)
    log = output / 'build.log'
    log.touch(mode=0o600)
    run_step('Core Flutter validation: locked dependencies',
             ['flutter', 'pub', 'get', '--enforce-lockfile'], log)
    run_step('Product build: configure Flutter iOS',
             ['flutter', 'build', 'ios', '--config-only', '--release', '--no-codesign', '--no-pub',
              '--build-name', args.build_name, '--build-number', args.build_number], log)
    run_step('Product build: locked CocoaPods dependencies', ['pod', 'install', '--deployment'], log, ROOT / 'ios')
    archive = output / 'OpenReading.xcarchive'
    run_step('Product build: signed archive',
             ['xcodebuild', '-workspace', 'ios/Runner.xcworkspace', '-scheme', 'Runner',
              '-configuration', 'Release', '-destination', 'generic/platform=iOS',
              '-archivePath', str(archive), *auth_arguments(),
              'CODE_SIGN_STYLE=Automatic', 'DEVELOPMENT_TEAM=' + os.environ['IOS_TEAM_ID'],
              'FLUTTER_BUILD_NAME=' + args.build_name, 'FLUTTER_BUILD_NUMBER=' + args.build_number,
              'archive'], log)
    app = validate_archive(archive, args.build_name, args.build_number)
    run_step('Product build: verify archive signature', ['codesign', '--verify', '--deep', '--strict', str(app)], log)
    options = output / 'ExportOptions.plist'
    options.write_bytes(plistlib.dumps(export_options(args.upload)))
    destination = output / 'export'
    label = 'App Store Connect upload' if args.upload else 'Product build: export signed IPA'
    run_step(label, ['xcodebuild', '-exportArchive', '-archivePath', str(archive),
                    '-exportPath', str(destination), '-exportOptionsPlist', str(options), *auth_arguments()], log)
    if args.upload:
        print('Xcode upload completed. Use connect.mjs status to confirm Apple processing before reporting TestFlight ready.')
    else:
        ipas = list(destination.glob('*.ipa'))
        if len(ipas) != 1:
            raise BuildError('Export did not produce exactly one IPA')
        digest = hashlib.sha256()
        with ipas[0].open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        (output / 'SHA256SUMS').write_text(f'{digest.hexdigest()}  export/{ipas[0].name}\n')
        print(f'Signed IPA exported: {ipas[0]}\nSHA256: {digest.hexdigest()}')
    return 0


def main(argv=None):
    try:
        return execute(parser().parse_args(argv))
    except BuildError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
