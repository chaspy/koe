"""Signing regressions, with no access to real keychains or installed apps."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, HOME=str(self.root), USER='test',
                        PATH=f'{self.root}:/usr/bin:/bin',
                        SIGN_KEYCHAIN=str(self.root / 'signing.keychain-db'),
                        SIGN_IDENTITY='Koe Code Signing', LOG=str(self.root / 'log'))

    def mock(self, name, body):
        path = self.root / name
        path.write_text('#!/bin/bash\nset -eu\n' + body)
        path.chmod(0o700)

    def run_script(self, name, *args):
        return subprocess.run(['bash', str(SCRIPTS / name), *map(str, args)],
                              env=self.env, text=True, capture_output=True)

    def test_export_versions_and_import_cleanup(self):
        self.mock('openssl', '''
echo "openssl $*" >> "$LOG"
case "$1" in
  rand) echo test-password ;;
  version) echo "$OPENSSL_VERSION" ;;
esac
''')
        self.mock('security', '''
echo "security $1" >> "$LOG"
case "$1" in
  create-keychain) touch "$SIGN_KEYCHAIN" ;;
  import) exit "$IMPORT_STATUS" ;;
  delete-keychain) rm "$SIGN_KEYCHAIN" ;;
  find-certificate) echo 'SHA-1: test' ;;
esac
''')
        for version in ['OpenSSL 3.6.2', 'OpenSSL 1.1.1w', 'LibreSSL 3.3.6']:
            for status in [0, 42]:
                with self.subTest(version=version, status=status):
                    self.env.update(OPENSSL_VERSION=version, IMPORT_STATUS=str(status))
                    (self.root / 'log').write_text('')
                    result = self.run_script('signing-setup.sh')
                    log = (self.root / 'log').read_text()
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual('pkcs12 -export -legacy' in log,
                                     version.startswith('OpenSSL 3.'))
                    self.assertEqual('security delete-generic-password' in log, status != 0)
                    self.assertEqual(Path(self.env['SIGN_KEYCHAIN']).exists(), status == 0)
                    if status:
                        self.assertNotIn('security set-key-partition-list', log)

    def test_install_requirements(self):
        self.mock('codesign', '''
[ "${FAIL_READ:-0}" = 0 ] || exit 1
echo "Executable=$3/Contents/MacOS/Koe" >&2
if [[ "$3" = */installed.app ]]; then
  echo "designated => $OLD_REQUIREMENT"
else
  echo "designated => $NEW_REQUIREMENT"
fi
''')
        installed = self.root / 'installed.app'
        built = self.root / 'build with spaces.app'
        self.env.update(OLD_REQUIREMENT='certificate leaf = old',
                        NEW_REQUIREMENT='certificate leaf = new')
        result = self.run_script('check-install-signature.sh', installed, built)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, '')
        installed.mkdir()
        result = self.run_script('check-install-signature.sh', installed, built)
        self.assertEqual(result.returncode, 0)
        self.assertIn('Accessibility / マイク', result.stderr)
        self.assertEqual(result.stdout, '')
        self.env['NEW_REQUIREMENT'] = self.env['OLD_REQUIREMENT']
        result = self.run_script('check-install-signature.sh', installed, built)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, '')
        self.env['FAIL_READ'] = '1'
        result = self.run_script('check-install-signature.sh', installed, built)
        self.assertEqual(result.returncode, 0)
        self.assertIn('署名を確認できません', result.stderr)


    def test_install_dir(self):
        system = self.root / 'Applications'
        home = self.root / 'home-apps'
        self.env['KOE_SYSTEM_APPS'] = str(system)
        # nothing in /Applications: install anywhere
        self.assertEqual(self.run_script('check-install-dir.sh', home, 'file').returncode, 0)
        (system / 'Koe.app').mkdir(parents=True)
        # default INSTALL_DIR would add a second Koe.app: stop and say how to choose
        result = self.run_script('check-install-dir.sh', home, 'file')
        self.assertEqual(result.returncode, 1)
        self.assertIn(f'make install INSTALL_DIR={system}', result.stderr)
        self.assertIn(f'make install INSTALL_DIR={home}', result.stderr)
        # installing into /Applications itself (with or without a trailing slash) replaces it
        self.assertEqual(self.run_script('check-install-dir.sh', system, 'file').returncode, 0)
        self.assertEqual(self.run_script('check-install-dir.sh', f'{system}/', 'file').returncode, 0)
        # INSTALL_DIR given on the command line or in the environment: the user chose
        for origin in ['command line', 'environment']:
            with self.subTest(origin=origin):
                self.assertEqual(self.run_script('check-install-dir.sh', home, origin).returncode, 0)


if __name__ == '__main__':
    unittest.main()
