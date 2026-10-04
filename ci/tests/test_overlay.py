"""Installed-file syntax checks and malformed-input regressions, entirely offline."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('overlay', ROOT / 'ci/lint/overlay.py')
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)
OVERLAYS = (ROOT / 'system', ROOT / 'iso/airootfs')


def configs(pattern):
    return sorted(path for root in OVERLAYS for path in root.glob(pattern)
                  if path.is_file() and not path.is_symlink())


def command(test, argv):
    env = dict(os.environ)
    # bash -n must not inherit a startup script from the caller.
    env.pop('BASH_ENV', None)
    env.pop('ENV', None)
    result = subprocess.run(argv, cwd=ROOT, env=env, text=True, capture_output=True, timeout=60)
    test.assertEqual(result.returncode, 0, f'{" ".join(argv)}\n{result.stdout}{result.stderr}')


class OverlayTests(unittest.TestCase):
    def check_files(self, paths, validator):
        self.assertTrue(paths, 'no matching overlay files; check discovery paths')
        for path in paths:
            with self.subTest(path=str(path.relative_to(ROOT))):
                validator(path.read_text(), path.relative_to(ROOT))

    def test_sysctl(self):
        for root in OVERLAYS:
            seen = {}
            for path in sorted(root.glob('**/sysctl.d/*.conf')):
                if not path.is_symlink():
                    with self.subTest(path=str(path.relative_to(ROOT))):
                        lint.sysctl(path.read_text(), path.relative_to(ROOT), seen)

    def test_modules_load(self):
        self.check_files(configs('**/modules-load.d/*.conf'), lint.modules)

    def test_modprobe(self):
        self.check_files(configs('**/modprobe.d/*.conf'),
                         lambda text, path: lint.modules(text, path, modprobe=True))

    def test_udev(self):
        self.check_files(configs('**/udev/rules.d/*.rules'), lint.udev)

    def test_tmpfiles(self):
        self.check_files(configs('**/tmpfiles.d/*.conf'), lint.tmpfiles)

    def test_systemd(self):
        suffixes = {'.conf', '.network', '.netdev', '.link'} | {'.' + key for key in lint.UNIT_SECTIONS}
        paths = [path for path in configs('**/systemd/**/*') if path.suffix in suffixes]
        self.check_files(paths, lambda text, path: lint.ini(text, path, lint.systemd_sections(path)))

    def test_networkmanager(self):
        self.check_files(configs('**/NetworkManager/**/*.conf'), lint.networkmanager)

    def test_pipewire_wireplumber_balance(self):
        paths = configs('**/pipewire/**/*.conf') + configs('**/wireplumber/**/*.conf')
        self.check_files(paths, lint.spa_json)

    def test_dconf(self):
        self.check_files(configs('**/dconf/profile/*'), lint.dconf_profile)
        self.check_files(configs('**/dconf/db/*.d/*'), lint.dconf_keyfile)
        # The profile must name the database the keyfiles compile into.
        for profile in configs('**/dconf/profile/*'):
            databases = {line.split(':', 1)[1] for line in profile.read_text().split() if line.startswith('system-db:')}
            for keyfile in configs('**/dconf/db/*.d/*'):
                self.assertIn(keyfile.parent.name.removesuffix('.d'), databases, keyfile)

    def test_no_gtk_settings_ini(self):
        # /usr/share/gtk-{3,4}.0/settings.ini belong to Arch's gtk3/gtk4 packages: shipping them
        # makes pacstrap fail with "conflicting files". Dark mode comes from dconf + the portal.
        self.assertEqual(list(configs('**/gtk-[34].0/settings.ini')), [])

    def test_portals(self):
        self.check_files(configs('**/xdg-desktop-portal/*portals.conf'), lint.portals)

    def test_fastfetch(self):
        path = ROOT / 'fish/fastfetch/config.jsonc'
        config = lint.jsonc(path.read_text(), path.relative_to(ROOT))
        self.assertEqual(config['logo']['type'], 'file')
        logo = path.parent / Path(config['logo']['source']).name
        self.assertTrue(logo.is_file(), 'logo file missing next to the config')
        logo_lines = logo.read_text().splitlines()
        self.assertTrue(all(line.startswith('$1') for line in logo_lines), 'every logo line sets its color')
        self.assertLessEqual(max(len(line) - 2 for line in logo_lines), 40, 'logo too wide for a small terminal')
        modules = [module['type'] if isinstance(module, dict) else module for module in config['modules']]
        self.assertLessEqual({'os', 'kernel', 'uptime', 'packages', 'shell', 'wm', 'terminal', 'cpu', 'gpu', 'memory'},
                             set(modules))

    def test_fish_syntax(self):
        fish = shutil.which('fish')
        if fish is None:
            self.skipTest('fish unavailable; install fish to enable syntax checking')
        paths = sorted((ROOT / 'fish').glob('*.fish')) + [ROOT / 'packages/gilgamesh-shell/gilgamesh.fish']
        self.assertTrue(paths, 'no fish scripts found')
        for path in paths:
            with self.subTest(path=str(path.relative_to(ROOT))):
                command(self, [fish, '--no-execute', str(path.relative_to(ROOT))])

    def test_mkinitcpio(self):
        for path in configs('**/mkinitcpio.conf.d/*.conf'):
            relative = path.relative_to(ROOT)
            with self.subTest(path=str(relative)):
                command(self, ['bash', '-n', str(relative)])
                lint.mkinitcpio(path.read_text(), relative,
                               lint.ARCHISO_HOOKS if relative.parts[0] == 'iso' else ())

    def test_system_symlinks(self):
        root = ROOT / 'system'
        for path in sorted(root.rglob('*')):
            if path.is_symlink():
                with self.subTest(path=str(path.relative_to(ROOT))):
                    lint.symlink(path, root)

    def test_hyprland_lua(self):
        compiler = next((shutil.which(name) for name in ('luac', 'luac5.4', 'luac5.3', 'luajit')
                         if shutil.which(name)), None)
        if compiler is None:
            self.skipTest('luac/luajit unavailable; install Lua to enable syntax checking')
        flag = '-bl' if Path(compiler).name == 'luajit' else '-p'
        command(self, [compiler, flag, 'hypr/hyprland.lua'])

    def test_shell_bash_syntax(self):
        scripts = list(lint.shell_scripts(ROOT))
        self.assertTrue(scripts, 'no shell scripts found')
        for path in scripts:
            with self.subTest(path=str(path.relative_to(ROOT))):
                command(self, ['bash', '-n', str(path.relative_to(ROOT))])

    def test_shellcheck(self):
        shellcheck = shutil.which('shellcheck')
        if shellcheck is None:
            self.skipTest('shellcheck unavailable; bash -n still runs for every shell script')
        # Resolve relative source directives beside each script, including build/lib.sh.
        scripts = [str(path.relative_to(ROOT)) for path in lint.shell_scripts(ROOT)]
        self.assertTrue(scripts, 'no shell scripts found')
        command(self, [shellcheck, '--norc', '--source-path=SCRIPTDIR', *scripts])

    def test_libalpm(self):
        self.check_files(configs('**/libalpm/hooks/*.hook') + configs('**/pacman.d/hooks/*.hook'), lint.alpm)


class ParserTests(unittest.TestCase):
    def rejects(self, validator, text, message, *args):
        with self.assertRaisesRegex(lint.Invalid, 'fixture:.*' + message):
            validator(text, 'fixture', *args)

    def test_sysctl_duplicates_and_comments(self):
        seen = {}
        lint.sysctl('# comment\nvm.swappiness = 180\n', 'first.conf', seen)
        self.rejects(lint.sysctl, 'vm/swappiness = 100', 'duplicate.*first.conf:2', seen)
        for text in ('vm.test = 1 # comment', 'vm.test = 1; comment'):
            self.rejects(lint.sysctl, text, 'inline comments', {})
        for text in ('vm.test 1', 'vm.test =', 'vm test = 1'):
            self.rejects(lint.sysctl, text, 'key = value', {})

    def test_modules_grammar(self):
        lint.modules('ntsync\ncpuidle-haltpoll\n', 'fixture')
        for text in ('foo bar', 'options foo x=1', 'foo # comment'):
            self.rejects(lint.modules, text, 'module name|inline comments')
        valid = 'options snd_hda_intel power_save=0\nblacklist watchdog\ninstall foo /bin/false\nsoftdep foo pre: bar baz post: quux'
        lint.modules(valid, 'fixture', True)
        for text in ('option foo x=1', 'blacklist foo bar', 'install foo', 'softdep foo bar',
                     'softdep foo pre:', 'softdep foo pre: post: bar', 'options foo x=1 # bad'):
            self.rejects(lint.modules, text, 'invalid modprobe|inline comments', True)

    def test_udev_quotes_commas_continuations_and_keys(self):
        lint.udev('SYMLINK=="disk/*", IMPORT{builtin}="blkid", PROGRAM="/bin/true"', 'fixture')
        lint.udev('ACTION=="add", \\\n ENV{TEST}="a,b", ATTR{value}="escaped\\\"quote"', 'fixture')
        for text, error in (
                ('ACTION="add"', 'does not support'), ('TYPO=="x"', 'unknown udev key'),
                ('ENV=="x"', 'invalid attribute'), ('ACTION{bad}=="x"', 'invalid attribute'),
                ('ACTION==add', 'invalid udev pair'), ('ACTION>="add"', 'invalid udev pair'),
                ('ACTION=="add",', 'expected comma'), ('ACTION=="add" # bad', 'expected comma'),
                ('ACTION=="add" ENV{X}="1"', 'expected comma'), ('ACTION=="add', 'invalid udev pair')):
            self.rejects(lint.udev, text, error)

    def test_tmpfiles_fields_types_and_quotes(self):
        lint.tmpfiles('w- /sys/example - - - - 1000\nf "/var/example name" 0644 root root - "two words"', 'fixture')
        for text, error in (
                ('w /sys/example - - - -', '7 fields'), ('j /tmp/x - - - - -', 'invalid tmpfiles type'),
                ('f tmp/x 0644 root root - -', 'absolute'), ('f /tmp/x 0999 root root - -', 'mode'),
                ('d /tmp/x 0755 root root tomorrow -', 'age'), ('d /tmp/x 0755 root root - - # bad', 'inline')):
            self.rejects(lint.tmpfiles, text, error)

    def test_ini_repeated_keys_sections_and_continuations(self):
        sections = lint.ini('[Service]\nExecStart=\nExecStart=/bin/true\nEnvironment="A=100%"\n'
                            '[Service]\nExecStart=/bin/echo \\\n hello', 'fixture', {'Service'})
        self.assertEqual(len(sections), 2)
        self.assertEqual(sections[0][1][0][1], '')
        for text, error in (('[Servcie]\nX=y', 'unknown section'), ('X=y', 'outside'),
                            ('[Service\nX=y', 'section header'), ('[Service]\nX y', 'key=value'),
                            ('[Service]\nX=y # bad', 'inline'), ('[Service] # bad', 'inline'),
                            ('[Service]\nX=y \\', 'unfinished')):
            self.rejects(lint.ini, text, error, {'Service'})

    def test_systemd_family_sections(self):
        for path, good, bad in (
                ('systemd/system/example.service.d/test.conf', 'Service', 'Socket'),
                ('systemd/timesyncd.conf.d/test.conf', 'Time', 'Timesync'),
                ('systemd/journald.conf', 'Journal', 'Service'),
                ('systemd/zram-generator.conf', 'zram0', 'zarm0')):
            allowed = lint.systemd_sections(path)
            lint.ini(f'[{good}]\nX=y', 'fixture', allowed)
            self.rejects(lint.ini, f'[{bad}]\nX=y', 'unknown section', allowed)

    def test_networkmanager_sections(self):
        lint.networkmanager('[main]\ndns=systemd-resolved\n[connection-wifi]\nipv6.method=auto', 'fixture')
        self.rejects(lint.networkmanager, '[mian]\ndns=default', 'unknown section')

    def test_dconf_profile_keyfile_and_values(self):
        lint.dconf_profile('# comment\nuser-db:user\nsystem-db:local\n', 'fixture')
        for text in ('user-db user', 'local-db:local', 'system-db:'):
            self.rejects(lint.dconf_profile, text, 'expected')
        lint.dconf_keyfile("[org/gnome/desktop/interface]\ncolor-scheme='prefer-dark'\nenable-animations=false\n"
                           "cursor-size=24\ntoolbar-style=@s 'icons'\n[org/gnome/shell]\nfavorite-apps=['a.desktop']\n", 'fixture')
        for text, error in (("[Org/Gnome]\nx='y'", 'unknown section'), ("[org//gnome]\nx='y'", 'unknown section'),
                            ("[org/gnome]\nColor_Scheme='y'", 'invalid dconf key'),
                            ("[org/gnome]\ncolor-scheme=prefer-dark", 'GVariant'),
                            ("[org/gnome]\ncolor-scheme='unterminated", 'GVariant'),
                            ("[org/gnome]\ncolor-scheme='x' # bad", 'inline')):
            self.rejects(lint.dconf_keyfile, text, error)

    def test_gtk_settings_and_portals(self):
        lint.gtk_settings('[Settings]\ngtk-theme-name=adw-gtk3-dark\ngtk-application-prefer-dark-theme=1\n', 'fixture')
        for text, error in (('[Setting]\ngtk-theme-name=x', 'unknown section'), ('[Settings]\ntheme=x', 'unknown GTK'),
                            ('[Settings]\ngtk-theme-name=', 'missing value')):
            self.rejects(lint.gtk_settings, text, error)
        lint.portals('[preferred]\ndefault=hyprland;gtk\norg.freedesktop.impl.portal.Settings=gtk\n'
                     'org.freedesktop.impl.portal.ScreenCast=none\norg.freedesktop.impl.portal.FileChooser=*\n', 'fixture')
        for text, error in (('[prefered]\ndefault=gtk', 'unknown section'), ('[preferred]\nScreenCast=gtk', 'unknown portal'),
                            ('[preferred]\ndefault=hyprland gtk', 'invalid backend'), ('[preferred]\ndefault=', 'invalid backend')):
            self.rejects(lint.portals, text, error)

    def test_jsonc_comments_strings_and_errors(self):
        self.assertEqual(lint.jsonc('// head\n{"a": "x // y /* z */", /* c\n c */ "b": [1, 2]}\n', 'fixture'),
                         {'a': 'x // y /* z */', 'b': [1, 2]})
        self.assertEqual(lint.jsonc('{"q": "\\" // not a comment"}', 'fixture'), {'q': '" // not a comment'})
        for text, error in (('{"a": 1,}', 'trailing comma'), ('/* open\n{"a": 1}', 'unterminated comment'),
                            ('"unterminated', 'Unterminated string')):
            self.rejects(lint.jsonc, text, error)
        # Line numbers survive comment removal.
        with self.assertRaisesRegex(lint.Invalid, r'^fixture:4: '):
            lint.jsonc('// one\n/* two\n   three */ {"a": 1\n"b"}', 'fixture')

    def test_spa_balance_ignores_comments_and_quoted_brackets(self):
        lint.spa_json('rules = [ { matches = [ { name = "a]#\\\"}" } ] } ] # ["', 'fixture')
        for text, error in (('a = [ { ] }', 'unmatched'), ('a = [', 'unclosed'),
                            ('a = "x', 'unterminated'), ('a = "x\ny"', 'newline')):
            self.rejects(lint.spa_json, text, error)

    def test_mkinitcpio_literal_arrays(self):
        lint.mkinitcpio('HOOKS=(systemd); COMPRESSION="lz4"', 'fixture')
        lint.mkinitcpio('HOOKS=(systemd\n "sd-vconsole" block)\nHOOKS+=(filesystems)', 'fixture')
        lint.mkinitcpio('HOOKS=(archiso)', 'fixture', lint.ARCHISO_HOOKS)
        for text, error in (('HOOKS=(systmed)', 'unknown mkinitcpio hook'),
                            ('HOOKS=(archiso)', 'unknown mkinitcpio hook'),
                            ('HOOKS=("$(touch forbidden)")', 'unknown mkinitcpio hook'),
                            ('HOOKS="systemd block"', 'literal HOOKS'),
                            ('HOOKS=(systemd', 'unclosed')):
            self.rejects(lint.mkinitcpio, text, error)

    def test_libalpm_required_keys_and_repeatable_triggers(self):
        trigger = '[Trigger]\nOperation=Install\nOperation=Upgrade\nType=Path\nTarget=usr/bin/example\n'
        action = '[Action]\nWhen=PostTransaction\nExec=/bin/true\n'
        lint.alpm(trigger + trigger + action + 'Depends=one\nDepends=two\nNeedsTargets', 'fixture')
        for text, error in ((action, r'requires \[Trigger\]'), (trigger, r'one \[Action\]'),
                            (trigger + action.replace('When=PostTransaction\n', ''), 'missing.*When'),
                            (trigger + action.replace('PostTransaction', 'PostTransactoin'), 'invalid.*When'),
                            (trigger + action + 'AbortOnFail', 'requires PreTransaction'),
                            (trigger + action + 'Typo=x', 'unknown libalpm'),
                            (trigger + action + action, r'one \[Action\]')):
            self.rejects(lint.alpm, text, error)

    def test_symlinks_use_overlay_root_and_reject_dangling_links_and_cycles(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'etc').mkdir()
            (root / 'etc/config').write_text('fixture')
            for name, target in (('relative', 'etc/config'), ('absolute', '/etc/config'), ('mask', '/dev/null')):
                link = root / name
                link.symlink_to(target)
                lint.symlink(link, root)
            for name, target, error in (('missing', '/etc/absent', 'dangling'),
                                        ('escape', '../outside', 'escapes'), ('cycle', 'cycle', 'cycle')):
                link = root / name
                link.symlink_to(target)
                with self.assertRaisesRegex(lint.Invalid, error):
                    lint.symlink(link, root)

    def test_shell_discovery_includes_extensionless_scripts_and_excludes_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, content in (('installer/install.sh', 'true'), ('ci/helper', '#!/usr/bin/env bash\n'),
                                  ('iso/guide', '#!/bin/sh\n'), ('build/cache/foreign.sh', 'false'),
                                  ('ci/artifacts/copied.sh', 'false'), ('ci/tool.py', '#!/usr/bin/env python3\n')):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            self.assertEqual({str(path.relative_to(root)) for path in lint.shell_scripts(root)},
                             {'installer/install.sh', 'ci/helper', 'iso/guide'})


if __name__ == '__main__':
    unittest.main()
