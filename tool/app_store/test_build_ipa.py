import contextlib
import io
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import build_ipa as build


class BuildIpaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'repo'
        (self.root / 'ios/Runner.xcworkspace').mkdir(parents=True)
        (self.root / 'pubspec.yaml').write_text('version: 2.6.4+260904001\n')
        self.key = self.base / 'test.p8'
        self.key.touch(mode=0o600)
        self.env = {'IOS_TEAM_ID': 'test-team'}
        for context in [patch.object(build, 'ROOT', self.root),
                        patch.object(build, 'OUT', self.root / 'build/app-store'),
                        patch.dict(os.environ, self.env, clear=True),
                        patch.object(build.shutil, 'which', return_value='/fake/tool'),
                        patch.object(build, 'read_command', side_effect=self.tool_output)]:
            context.start()
            self.addCleanup(context.stop)

    def tool_output(self, command):
        return {'xcodebuild': 'Xcode 26.4\nBuild version 17E202',
                'xcode-select': '/Applications/Xcode.app/Contents/Developer',
                'xcrun': '26.4'}[command[0]]

    def args(self, *extra):
        result = build.parser().parse_args(['--build-number', '1', *extra])
        result.build_name = result.build_name or build.version_from_pubspec()
        return result

    def credentials(self):
        os.environ.update(ASC_KEY_ID='test-key', ASC_ISSUER_ID='test-issuer', ASC_KEY_PATH=str(self.key))

    def archive(self, archive, *, version='2.6.4', number='1', bundle=build.BUNDLE_ID):
        app = archive / 'Products/Applications/OpenReading.app'
        (app / '_CodeSignature').mkdir(parents=True)
        (app / '_CodeSignature/CodeResources').touch()
        (app / 'embedded.mobileprovision').touch()
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle, 'CFBundleShortVersionString': version,
            'CFBundleVersion': number, 'ITSAppUsesNonExemptEncryption': False}))
        (app / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({'NSPrivacyAccessedAPITypes': [{
            'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults',
            'NSPrivacyAccessedAPITypeReasons': ['CA92.1']}]}))
        return app

    def test_accepts_apple_build_strings(self):
        for number in ['1', '9999', '2609.5.1', '1.0.0', '260904001', '2.2026.216', '1.520.1314']:
            with self.subTest(number=number):
                build.check_inputs(self.args('--build-number', number))

    def test_rejects_invalid_build_strings(self):
        for number in ['0', '01', '-1', '1.a', '1..2', '1.2.3.4', '../1']:
            with self.subTest(number=number), self.assertRaises(build.BuildError):
                build.check_inputs(self.args('--build-number', number))

    def test_rejects_invalid_marketing_version(self):
        with self.assertRaisesRegex(build.BuildError, 'major.minor.patch'):
            build.check_inputs(self.args('--build-name', '2.6'))

    def test_defaults_to_export(self):
        self.assertFalse(self.args().upload)
        self.assertEqual(build.export_options(False)['destination'], 'export')
        self.assertFalse(build.export_options(False)['manageAppVersionAndBuildNumber'])
        self.assertFalse(build.export_options(False)['testFlightInternalTestingOnly'])

    def test_upload_requires_credentials_before_build(self):
        with self.assertRaisesRegex(build.BuildError, 'credentials'):
            build.check_inputs(self.args('--upload'))

    def test_partial_credentials_fail(self):
        os.environ['ASC_KEY_ID'] = 'only-one'
        with self.assertRaisesRegex(build.BuildError, 'together'):
            build.check_inputs(self.args())

    def test_credentials_must_be_outside_repo_and_private(self):
        self.credentials()
        self.key.chmod(0o644)
        with self.assertRaisesRegex(build.BuildError, 'permissions'):
            build.check_inputs(self.args())
        inside = self.root / 'private.p8'
        inside.touch(mode=0o600)
        os.environ['ASC_KEY_PATH'] = str(inside)
        with self.assertRaisesRegex(build.BuildError, 'outside'):
            build.check_inputs(self.args())

    def test_beta_seed_suffix_is_detected(self):
        with patch.object(build, 'read_command', return_value='Xcode 27.0\nBuild version 27A5252f'):
            with self.assertRaisesRegex(build.BuildError, 'beta/seed'):
                build.check_inputs(self.args())

    def test_beta_path_is_detected(self):
        os.environ['DEVELOPER_DIR'] = '/Applications/Xcode-beta.app/Contents/Developer'
        with self.assertRaisesRegex(build.BuildError, 'beta/seed'):
            build.check_inputs(self.args())
        build.check_inputs(self.args('--allow-beta-xcode'))
        with self.assertRaisesRegex(build.BuildError, 'cannot'):
            build.check_inputs(self.args('--allow-beta-xcode', '--upload'))

    def test_check_does_not_build_or_create_output(self):
        with patch.object(build, 'run_step') as run, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(build.execute(self.args('--check')), 0)
            run.assert_not_called()
        self.assertFalse(build.OUT.exists())

    def test_existing_output_is_not_overwritten(self):
        target = build.OUT / '2.6.4-1'
        target.mkdir(parents=True)
        sentinel = target / 'keep.txt'
        sentinel.write_text('owned archive')
        with self.assertRaisesRegex(build.BuildError, 'refusing overwrite'):
            build.execute(self.args())
        self.assertEqual(sentinel.read_text(), 'owned archive')

    def test_archive_identity_mismatch_is_rejected(self):
        for field in ['version', 'number', 'bundle']:
            with self.subTest(field=field):
                archive = self.base / field
                self.archive(archive, **{field: 'wrong'})
                with self.assertRaisesRegex(build.BuildError, 'identity'):
                    build.validate_archive(archive, '2.6.4', '1')

    def test_archive_needs_privacy_and_signing(self):
        archive = self.base / 'archive'
        app = self.archive(archive)
        self.assertEqual(build.validate_archive(archive, '2.6.4', '1'), app)
        (app / 'embedded.mobileprovision').unlink()
        with self.assertRaisesRegex(build.BuildError, 'unsigned'):
            build.validate_archive(archive, '2.6.4', '1')
        (app / 'PrivacyInfo.xcprivacy').unlink()
        with self.assertRaisesRegex(build.BuildError, 'PrivacyInfo'):
            build.validate_archive(archive, '2.6.4', '1')

    def test_export_and_upload_use_expected_commands(self):
        self.credentials()
        for upload, number in [(False, '1'), (True, '2')]:
            calls = []
            def fake_step(label, command, log, cwd=None):
                calls.append((label, command, cwd))
                if 'archive' in command:
                    self.archive(Path(command[command.index('-archivePath') + 1]), number=number)
                if '-exportArchive' in command and not upload:
                    dest = Path(command[command.index('-exportPath') + 1])
                    dest.mkdir()
                    (dest / 'OpenReading.ipa').write_bytes(b'fake-ipa')
            with patch.object(build, 'run_step', side_effect=fake_step), contextlib.redirect_stdout(io.StringIO()):
                args = self.args('--build-number', number, *(['--upload'] if upload else []))
                self.assertEqual(build.execute(args), 0)
            pod = next(call for call in calls if call[1][0] == 'pod')
            self.assertEqual(pod[2], self.root / 'ios')
            xcode = [call[1] for call in calls if call[1][0] == 'xcodebuild']
            self.assertEqual(len(xcode), 2)
            for command in xcode:
                self.assertIn('-authenticationKeyPath', command)
                self.assertIn('-allowProvisioningUpdates', command)
            options = plistlib.loads((build.OUT / f'2.6.4-{number}/ExportOptions.plist').read_bytes())
            self.assertEqual(options['destination'], 'upload' if upload else 'export')
            self.assertEqual((build.OUT / f'2.6.4-{number}/SHA256SUMS').exists(), not upload)

    def test_failed_step_does_not_echo_secret_command(self):
        secret = 'do-not-print-key-id'
        error = build.subprocess.CalledProcessError(1, ['xcodebuild', secret])
        output = io.StringIO()
        log = self.base / 'build.log'
        with patch.object(build.subprocess, 'run', side_effect=error), contextlib.redirect_stdout(output):
            with self.assertRaises(build.BuildError) as raised:
                build.run_step('Archive', ['xcodebuild', secret], log)
        self.assertNotIn(secret, output.getvalue() + str(raised.exception) + log.read_text())


if __name__ == '__main__':
    unittest.main()
