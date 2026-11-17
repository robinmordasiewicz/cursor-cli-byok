"""Exercise release failure boundaries with fake Apple tools, never real credentials."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FAKE_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['TEST_CALL_LOG'], 'a') as log:
    log.write(name + '\n')
if name == 'uname':
    print('Darwin')
elif name == 'security' and 'find-identity' in args:
    print('1) ' + 'A' * 40 + ' "Developer ID Application: Test (TESTTEAM)"')
elif name == 'lipo':
    print('arm64')
elif name == 'codesign' and '-dv' in args:
    print('Authority=Developer ID Application: Test\nTeamIdentifier=TESTTEAM', file=sys.stderr)
    if os.environ.get('TEST_ADHOC') == '1':
        print('Signature=adhoc', file=sys.stderr)
elif name == 'hdiutil':
    pathlib.Path(args[-1]).write_bytes(b'fake-disk-image')
elif name == 'xcrun' and args[:2] == ['notarytool', 'submit']:
    print(json.dumps({'status': os.environ.get('TEST_NOTARY_STATUS', 'Accepted'), 'id': 'test-submission'}))
elif name == 'xcrun' and args[:2] == ['stapler', 'staple']:
    with open(args[-1], 'ab') as image:
        image.write(b'-stapled')
elif name == 'spctl' and os.environ.get('TEST_GATEKEEPER_REJECT') == '1':
    sys.exit(1)
elif name == 'spctl':
    print('accepted\nsource=Notarized Developer ID', file=sys.stderr)
'''


class SigningBoundaryTests(unittest.TestCase):
    def run_signer(self, **overrides):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        tools = root / 'tools'
        tools.mkdir()
        for name in ['uname', 'security', 'lipo', 'codesign', 'hdiutil', 'xcrun', 'spctl']:
            path = tools / name
            path.write_text(FAKE_TOOL)
            path.chmod(0o755)
        binary = root / 'cursor-cli-byok'
        binary.write_bytes(b'fake-executable')
        binary.chmod(0o755)
        self.output = root / 'artifacts'
        self.log = root / 'calls'
        environment = os.environ.copy()
        environment.update({
            'PATH': str(tools) + os.pathsep + environment['PATH'],
            'RUNNER_TEMP': str(root), 'TEST_CALL_LOG': str(self.log),
            'APPLE_CERTIFICATE_BASE64': base64.b64encode(b'fake-certificate').decode(),
            'APPLE_CERTIFICATE_PASSWORD': 'test-only', 'APPLE_ID': 'test@example.invalid',
            'APPLE_PASSWORD': 'test-only', 'APPLE_TEAM_ID': 'TESTTEAM',
            'SOURCE_COMMIT': '1' * 40,
        })
        environment.update(overrides)
        return subprocess.run(
            ['bash', str(ROOT / 'scripts/sign-macos.sh'), str(binary), 'v0.2.0-internal.1', str(self.output)],
            cwd=ROOT, env=environment, capture_output=True, text=True,
        )

    def test_rejected_notarization_never_produces_release_assets(self):
        result = self.run_signer(TEST_NOTARY_STATUS='Invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Apple did not accept', result.stderr)
        self.assertFalse(self.output.exists())
        self.assertNotIn('spctl', self.log.read_text())

    def test_gatekeeper_rejection_never_produces_release_assets(self):
        result = self.run_signer(TEST_GATEKEEPER_REJECT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_receipt_and_checksum_cover_the_stapled_artifact(self):
        result = self.run_signer()
        self.assertEqual(result.returncode, 0, result.stderr)
        image = self.output / 'cursor-cli-byok-darwin-arm64.dmg'
        self.assertTrue(image.read_bytes().endswith(b'-stapled'))
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        receipt = json.loads((self.output / 'cursor-cli-byok-darwin-arm64.receipt.json').read_text())
        self.assertEqual(receipt['dmg_sha256'], digest)
        self.assertEqual(receipt['source_commit'], '1' * 40)
        self.assertEqual(receipt['notarization_status'], 'Accepted')
        self.assertTrue(receipt['gatekeeper_accepted'])
        self.assertEqual((self.output / (image.name + '.sha256')).read_text().split()[0], digest)
        self.assertFalse(any(Path(self.temp.name).glob('cursor-byok-signing.*')))

    def test_missing_credentials_fail_before_keychain_creation(self):
        result = self.run_signer(APPLE_PASSWORD='')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing release secret', result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ['uname'])

    def test_adhoc_signature_cannot_be_published(self):
        result = self.run_signer(TEST_ADHOC='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
