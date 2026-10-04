"""Offline syntax checks for the installed overlays; never execute their contents."""
from pathlib import Path
import json
import os
import re
import shlex


class Invalid(ValueError):
    pass


def require(condition, path, number, message):
    if not condition:
        raise Invalid(f'{path}:{number}: {message}')


def lines(text, path, comments='#;', continuation=False):
    pending = ''
    start = 0
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith(tuple(comments)):
            continue
        if not pending:
            start = number
        if continuation and (len(line) - len(line.rstrip('\\'))) % 2:
            pending += line[:-1] + ' '
            continue
        yield start, pending + line
        pending = ''
    require(not pending, path, start, 'unfinished line continuation')


def no_inline_comment(line, path, number, markers='#;'):
    quote = None
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
        elif char == '\\':
            escaped = True
        elif quote:
            if char == quote:
                quote = None
        elif char in '\"\'':
            quote = char
        elif char in markers and (index == 0 or line[index - 1].isspace()):
            raise Invalid(f'{path}:{number}: inline comments are forbidden; use a separate line')


def words(line, path, number):
    try:
        return shlex.split(line, comments=False)
    except ValueError as error:
        raise Invalid(f'{path}:{number}: {error}') from error


def sysctl(text, path, seen):
    for number, line in lines(text, path):
        require('#' not in line and ';' not in line, path, number,
                'inline comments are forbidden; use a separate line')
        match = re.fullmatch(r'(-?)([A-Za-z0-9_./*-]+)\s*=\s*(\S(?:.*\S)?)', line)
        require(match, path, number, 'expected key = value')
        key = match[2]
        # sysctl interchanges dots and slashes when the first separator is a dot.
        if re.search(r'[./]', key) and re.search(r'[./]', key)[0] == '.':
            key = key.translate(str.maketrans('./', '/.'))
        require(key not in seen, path, number,
                f'duplicate sysctl key {match[2]} (first at {seen.get(key)})')
        seen[key] = f'{path}:{number}'


MODULE = r'[A-Za-z0-9_][A-Za-z0-9_-]*'


def modules(text, path, modprobe=False):
    for number, line in lines(text, path, comments='#', continuation=modprobe):
        no_inline_comment(line, path, number, markers='#')
        fields = words(line, path, number)
        if not modprobe:
            require(re.fullmatch(MODULE, line), path, number, 'expected one module name')
            continue
        require(len(fields) >= 2, path, number,
                'expected directive and module name')
        command, module, *args = fields
        require(command == 'alias' or re.fullmatch(MODULE, module), path, number,
                'expected a valid module name')
        if command == 'blacklist':
            valid = not args
        elif command == 'options':
            valid = bool(args) and all(re.fullmatch(r'[A-Za-z0-9_]+(?:=.*)?', arg) for arg in args)
        elif command in ('install', 'remove'):
            valid = bool(args)
        elif command == 'softdep':
            groups = []
            count = 0
            valid = bool(args)
            for arg in args:
                if arg in ('pre:', 'post:'):
                    valid = valid and arg not in groups and (not groups or count > 0)
                    groups.append(arg)
                    count = 0
                else:
                    valid = valid and bool(groups) and bool(re.fullmatch(MODULE, arg))
                    count += 1
            valid = valid and bool(groups) and count > 0
        elif command == 'weakdep':
            valid = bool(args) and all(re.fullmatch(MODULE, arg) for arg in args)
        elif command == 'alias':
            valid = len(args) == 1 and bool(re.fullmatch(MODULE, args[0]))
        else:
            valid = False
        require(valid, path, number, f'invalid modprobe {command} directive')


UDEV_MATCH = set('ACTION DEVPATH KERNEL KERNELS SUBSYSTEM SUBSYSTEMS DRIVER DRIVERS '
                 'ATTR ATTRS SYSCTL ENV CONST NAME SYMLINK TAG TAGS TEST PROGRAM RESULT IMPORT'.split())
UDEV_ASSIGN = set('NAME SYMLINK OWNER GROUP MODE SECLABEL ATTR SYSCTL ENV TAG RUN '
                  'LABEL GOTO OPTIONS IMPORT PROGRAM'.split())
UDEV_ATTR = set('ATTR ATTRS SYSCTL ENV CONST SECLABEL IMPORT'.split())
UDEV_OPTIONAL_ATTR = {'TEST', 'PROGRAM', 'RUN'}
UDEV_PAIR = re.compile(r'([A-Z][A-Z0-9_]*)(?:\{([^{}\s]+)\})?\s*'
                       r'(==|!=|\+=|-=|:=|=)\s*[ei]?"((?:[^"\\]|\\.)*)"')


def udev(text, path):
    for number, line in lines(text, path, comments='#', continuation=True):
        position = 0
        while True:
            match = UDEV_PAIR.match(line, position)
            require(match, path, number, f'invalid udev pair near {line[position:]!r}')
            key, attr, operator, value = match.groups()
            require(key in UDEV_MATCH | UDEV_ASSIGN, path, number, f'unknown udev key {key}')
            require((key in UDEV_ATTR and attr is not None)
                    or (key in UDEV_OPTIONAL_ATTR)
                    or (key not in UDEV_ATTR and attr is None), path, number,
                    f'invalid attribute for udev key {key}')
            allowed = UDEV_MATCH if operator in ('==', '!=') else UDEV_ASSIGN
            require(key in allowed, path, number, f'{key} does not support {operator}')
            if operator in ('+=', '-='):
                require(key in {'SYMLINK', 'ENV', 'TAG', 'RUN', 'OPTIONS'}, path, number,
                        f'{key} does not support {operator}')
            if key in ('LABEL', 'GOTO'):
                require(operator == '=', path, number, f'{key} requires =')
            if key in ('PROGRAM', 'IMPORT'):
                require(operator in ('=', '==', '!='), path, number, f'{key} does not support {operator}')
            position = match.end()
            rest = line[position:].lstrip()
            if not rest:
                break
            require(rest.startswith(',') and rest[1:].strip(), path, number,
                    'expected comma and another udev pair (no inline comments)')
            position = len(line) - len(rest) + 1
            while position < len(line) and line[position].isspace():
                position += 1


def tmpfiles(text, path):
    for number, line in lines(text, path, comments='#'):
        no_inline_comment(line, path, number, markers='#')
        fields = words(line, path, number)
        require(len(fields) >= 7, path, number,
                'expected 7 fields: type path mode user group age argument (use - for omitted fields)')
        kind, target, mode, user, group, age = fields[:6]
        require(re.fullmatch(r'[fFwWdDevqQpPLlcCbBxXrRzZtThHaA][+!~^$=\-]*', kind),
                path, number, f'invalid tmpfiles type {kind}')
        require(len(set(kind[1:])) == len(kind[1:]), path, number, 'duplicate tmpfiles type modifier')
        require(target.startswith(('/', '%')), path, number, 'tmpfiles path must be absolute or a specifier')
        require(mode == '-' or re.fullmatch(r'[:~]?[0-7]{3,4}', mode), path, number,
                f'invalid tmpfiles mode {mode}')
        for label, value in (('user', user), ('group', group)):
            require(re.fullmatch(r'[-A-Za-z0-9_.%:]+', value), path, number, f'invalid tmpfiles {label}')
        require(age == '-' or re.fullmatch(r'(?:[abcmABCM]+:)?~?(?:\d+(?:\.\d+)?[a-z]*)+', age),
                path, number, f'invalid tmpfiles age {age}')
        if kind[0] not in 'fwW':
            require(len(fields) == 7, path, number, 'extra tmpfiles fields; quote arguments containing spaces')


UNIT_SECTIONS = {
    'service': 'Service', 'socket': 'Socket', 'target': None, 'device': None,
    'mount': 'Mount', 'automount': 'Automount', 'swap': 'Swap', 'timer': 'Timer',
    'path': 'Path', 'slice': 'Slice', 'scope': 'Scope',
}
CONFIG_SECTIONS = {
    'journald': {'Journal'}, 'timesyncd': {'Time'}, 'system': {'Manager'},
    'user': {'Manager'}, 'logind': {'Login'}, 'resolved': {'Resolve'},
    'networkd': {'Network', 'DHCPv4', 'DHCPv6', 'DHCPServer', 'IPv6AcceptRA', 'IPv6AddressLabel'},
    'coredump': {'Coredump'}, 'oomd': {'OOM'}, 'sleep': {'Sleep'}, 'pstore': {'PStore'},
}
NETWORK_SECTIONS = set('Match Link Network Address Neighbor IPv6AddressLabel RoutingPolicyRule '
                       'Route DHCPv4 DHCPv6 DHCPServer DHCPServerStaticLease IPv6AcceptRA '
                       'IPv6SendRA IPv6Prefix IPv6RoutePrefix Bridge BridgeFDB BridgeVLAN '
                       'CAN QDisc TrafficControlQueueingDiscipline'.split())


def systemd_sections(path):
    path = Path(path)
    for part in reversed(path.parts):
        name = part.removesuffix('.d')
        suffix = name.rsplit('.', 1)[-1]
        if suffix in UNIT_SECTIONS:
            return {'Unit', 'Install'} | ({UNIT_SECTIONS[suffix]} if UNIT_SECTIONS[suffix] else set())
        if name == 'zram-generator.conf':
            return lambda section: section == 'global' or bool(re.fullmatch(r'zram\d+', section))
        if suffix == 'conf' and name[:-5] in CONFIG_SECTIONS:
            return CONFIG_SECTIONS[name[:-5]]
        if suffix == 'network':
            return NETWORK_SECTIONS
        if suffix == 'link':
            return {'Match', 'Link', 'SR-IOV'}
        if suffix == 'netdev':
            return {'Match', 'NetDev', 'Bridge', 'Bond', 'VLAN', 'MACVLAN', 'IPVLAN',
                    'VXLAN', 'Tunnel', 'WireGuard', 'WireGuardPeer', 'Tun', 'Tap', 'VRF', 'Veth'}
    raise Invalid(f'{path}:1: unrecognized systemd config family; add its section names to the lint checker')


def ini(text, path, allowed, inline=True, flags=()):
    sections = []
    current = None
    for number, line in lines(text, path, continuation=True):
        if inline:
            no_inline_comment(line, path, number)
        if line.startswith('['):
            match = re.fullmatch(r'\[([^\[\]]+)\]', line)
            require(match, path, number, 'invalid INI section header')
            name = match[1]
            require(allowed(name) if callable(allowed) else name in allowed,
                    path, number, f'unknown section [{name}]')
            current = []
            sections.append((name, current))
        else:
            require(current is not None, path, number, 'setting outside an INI section')
            match = re.fullmatch(r'([A-Za-z0-9_.-]+)\s*=\s*(.*)', line)
            require(match or line in flags, path, number, 'expected key=value')
            key, value = match.groups() if match else (line, None)
            current.append((key, value, number))
    require(sections, path, 1, 'expected at least one INI section')
    return sections


def networkmanager(text, path):
    allowed = {'main', 'logging', 'device', 'connection', 'connectivity', 'keyfile',
               'ifupdown', 'global-dns'}
    return ini(text, path, lambda name: name in allowed or bool(re.fullmatch(
        r'(?:device|connection|global-dns-domain)-[^\[\]\s]+', name)))


def dconf_profile(text, path):
    for number, line in lines(text, path, comments='#'):
        require(re.fullmatch(r'(?:user|system|service|file)-db:\S+', line), path, number,
                'expected <user|system|service|file>-db:<name>')


DCONF_VALUE = re.compile(r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"|true|false|-?\d+(?:\.\d+)?|[\[(@].+")


def dconf_keyfile(text, path):
    # GKeyFile whose sections are dconf directories and whose values are GVariant text.
    sections = ini(text, path, lambda name: bool(re.fullmatch(r'[a-z0-9-]+(?:/[a-z0-9-]+)*', name)))
    for name, entries in sections:
        for key, value, number in entries:
            require(re.fullmatch(r'[a-z0-9-]+', key), path, number, f'invalid dconf key {key}')
            require(DCONF_VALUE.fullmatch(value), path, number, f'invalid GVariant value for {key}')


def gtk_settings(text, path):
    for name, entries in ini(text, path, {'Settings'}):
        for key, value, number in entries:
            require(re.fullmatch(r'gtk-[a-z-]+', key), path, number, f'unknown GTK setting {key}')
            require(value, path, number, f'missing value for {key}')


def portals(text, path):
    # xdg-desktop-portal's portals.conf: backends per interface, none, or * for any.
    for name, entries in ini(text, path, {'preferred'}):
        for key, value, number in entries:
            require(key == 'default' or re.fullmatch(r'org\.freedesktop\.impl\.portal\.[A-Za-z]+', key),
                    path, number, f'unknown portal interface {key}')
            require(re.fullmatch(r'none|\*|[a-z0-9_.-]+(?:;[a-z0-9_.-]+)*;?', value), path, number,
                    f'invalid backend list for {key}')


def jsonc(text, path):
    # JSON with // and /* */ comments outside strings (fastfetch's config format).
    out = []
    index = 0
    quote = False
    while index < len(text):
        char = text[index]
        if quote:
            out.append(char)
            if char == '\\' and index + 1 < len(text):
                index += 1
                out.append(text[index])
            elif char == '"':
                quote = False
        elif char == '"':
            quote = True
            out.append(char)
        elif text.startswith('//', index):
            end = text.find('\n', index)
            index = len(text) if end < 0 else end
            continue
        elif text.startswith('/*', index):
            end = text.find('*/', index + 2)
            require(end >= 0, path, text.count('\n', 0, index) + 1, 'unterminated comment')
            out.append('\n' * text.count('\n', index, end))
            index = end + 2
            continue
        else:
            out.append(char)
        index += 1
    try:
        return json.loads(''.join(out))
    except json.JSONDecodeError as error:
        raise Invalid(f'{path}:{error.lineno}: {error.msg}') from error


def spa_json(text, path):
    # SPA-JSON permits unquoted keys/values, =, optional commas and # comments.
    stack = []
    quote = False
    escaped = False
    comment = False
    number = 1
    for char in text:
        if char == '\n':
            require(not quote, path, number, 'newline in SPA-JSON string')
            comment = False
            number += 1
        elif comment:
            continue
        elif quote:
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == '"':
                quote = False
        elif char == '#':
            comment = True
        elif char == '"':
            quote = True
        elif char in '[{':
            stack.append((char, number))
        elif char in ']}':
            require(stack and stack[-1][0] == {']': '[', '}': '{'}[char], path, number,
                    f'unmatched SPA-JSON {char}')
            stack.pop()
    require(not quote, path, number, 'unterminated SPA-JSON string')
    require(not stack, path, stack[-1][1] if stack else number, 'unclosed SPA-JSON bracket')


MKINITCPIO_HOOKS = set('base udev systemd autodetect microcode modconf kms keyboard keymap '
                      'consolefont sd-vconsole block filesystems fsck resume encrypt sd-encrypt '
                      'shutdown usr btrfs lvm2 mdadm_udev mdadm dmraid net nfs sd-shutdown'.split())
ARCHISO_HOOKS = set('memdisk archiso archiso_loop_mnt archiso_pxe_common archiso_pxe_nbd '
                   'archiso_pxe_http archiso_pxe_nfs'.split())


def mkinitcpio(text, path, extra=()):
    # Read only literal HOOKS arrays; never source a config to obtain its values.
    lexer = shlex.shlex(text, posix=True, punctuation_chars='()')
    lexer.whitespace_split = True
    tokens = []
    try:
        while True:
            token = lexer.get_token()
            if token is None:
                break
            tokens.append((token, lexer.lineno))
    except ValueError as error:
        raise Invalid(f'{path}:{lexer.lineno}: {error}') from error
    index = 0
    while index < len(tokens):
        token, number = tokens[index]
        if token.startswith('HOOKS'):
            require(token in ('HOOKS=', 'HOOKS+='), path, number, 'use a literal HOOKS=(...) array')
            index += 1
            require(index < len(tokens) and tokens[index][0] == '(', path, number,
                    'use a literal HOOKS=(...) array')
            index += 1
            while index < len(tokens) and tokens[index][0] != ')':
                hook, number = tokens[index]
                require(hook in MKINITCPIO_HOOKS | set(extra), path, number,
                        f'unknown mkinitcpio hook {hook!r}; update the known hook set for a new provider')
                index += 1
            require(index < len(tokens), path, number, 'unclosed HOOKS array')
        index += 1


def alpm(text, path):
    sections = ini(text, path, {'Trigger', 'Action'}, inline=False,
                   flags={'AbortOnFail', 'NeedsTargets'})
    require(sum(name == 'Action' for name, entries in sections) == 1, path, 1,
            'libalpm hook requires exactly one [Action]')
    require(any(name == 'Trigger' for name, entries in sections), path, 1,
            'libalpm hook requires [Trigger]')
    for name, entries in sections:
        allowed = ({'Operation', 'Type', 'Target'} if name == 'Trigger' else
                   {'Description', 'When', 'Exec', 'Depends', 'AbortOnFail', 'NeedsTargets'})
        required = {'Operation', 'Type', 'Target'} if name == 'Trigger' else {'When', 'Exec'}
        present = {}
        for key, value, number in entries:
            require(key in allowed, path, number, f'unknown libalpm {name} key {key}')
            require(key not in present or key in {'Operation', 'Target', 'Depends'}, path, number,
                    f'duplicate libalpm {key}')
            present[key] = value
            require(value is None if key in {'AbortOnFail', 'NeedsTargets'} else bool(value),
                    path, number, f'invalid value for libalpm {key}')
            enums = {'Operation': {'Install', 'Upgrade', 'Remove'},
                     'Type': {'Path', 'Package'}, 'When': {'PreTransaction', 'PostTransaction'}}
            if key in enums:
                require(value in enums[key], path, number, f'invalid libalpm {key}: {value}')
            if key == 'Exec':
                argv = words(value, path, number)
                require(argv and argv[0].startswith('/'), path, number, 'Exec requires an absolute executable')
        require(required <= present.keys(), path, 1,
                f'[{name}] missing required keys: {", ".join(sorted(required - present.keys()))}')
        if 'AbortOnFail' in present:
            require(present['When'] == 'PreTransaction', path, 1, 'AbortOnFail requires PreTransaction')


def symlink(path, root):
    # Resolve against the installed root, never against the CI machine's /etc or /usr.
    pending = list(path.relative_to(root).parts)
    resolved = []
    followed = 0
    while pending:
        part = pending.pop(0)
        if part in ('', '.'):
            continue
        if part == '..':
            require(resolved, path, 1, 'symlink escapes the installed root')
            resolved.pop()
            continue
        candidate = root.joinpath(*resolved, part)
        if candidate.is_symlink():
            followed += 1
            require(followed <= 40, path, 1, 'symlink cycle or excessive link depth')
            target = candidate.readlink()
            if str(target) == '/dev/null' and not pending:
                return
            if target.is_absolute():
                resolved = []
                pending = list(target.parts[1:]) + pending
            else:
                pending = list(target.parts) + pending
        else:
            require(candidate.exists(), path, 1, f'dangling installed symlink component: /{"/".join(resolved + [part])}')
            require(not pending or candidate.is_dir(), path, 1, 'symlink traverses a non-directory')
            resolved.append(part)


def shell_scripts(root):
    ignored = {'.git', '__pycache__', 'artifacts', 'cache', 'out', 'work'}
    for directory in ('installer', 'build', 'ci', 'iso'):
        for folder, directories, files in os.walk(root / directory):
            directories[:] = sorted(set(directories) - ignored)
            for name in sorted(files):
                path = Path(folder) / name
                if path.is_symlink() or not path.is_file():
                    continue
                with path.open('rb') as stream:
                    first = stream.readline(256)
                if path.suffix == '.sh' or re.match(rb'#!\s*(?:\S*/)?(?:env\s+(?:-S\s+)?)?(?:bash|sh|dash|ksh)(?:\s|$)', first):
                    yield path
