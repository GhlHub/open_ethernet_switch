#!/usr/bin/env python3
"""Read/save KR260 settings, including a PBKDF2 password verifier.

Viewing is public; writes require the current administrator credentials.
HTTP Basic authentication is unencrypted on this lab HTTP interface.
Passwords are prompted, never command-line arguments.
"""
import argparse
import base64
import getpass
import hashlib
import json
import secrets
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='10.0.1.214')
    parser.add_argument('--auth-user', help='Current administrator username (default: stored username)')
    parser.add_argument('--username', help='Set administrator username (requires --password)')
    parser.add_argument('--password', action='store_true', help='Prompt for a new password')
    parser.add_argument('--save', action='store_true', help='Save current defaults/settings to microSD')
    parser.add_argument('--dhcp', choices=['on', 'off'])
    for field in ['ip', 'netmask', 'gateway']:
        parser.add_argument('--' + field)
    args = parser.parse_args()
    if args.username and not args.password:
        parser.error('--username requires --password to update credentials together')
    url = 'http://' + args.host + '/api/config'
    with urllib.request.urlopen(url, timeout=10) as response:
        cfg = json.load(response)
    changed = args.save or args.password or args.dhcp is not None or any(
        getattr(args, f) is not None for f in ['ip', 'netmask', 'gateway'])
    if not changed:
        print(json.dumps(cfg, indent=2))
        return
    current = getpass.getpass('Current administrator password: ')
    authorization = 'Basic ' + base64.b64encode(
        ((args.auth_user or cfg['username']) + ':' + current).encode('utf-8')).decode('ascii')
    del current
    fields = dict(mask=cfg['admin'], sfp=cfg['sfp'], dhcp=int(cfg['dhcp']),
                  ip=cfg['ip'], netmask=cfg['netmask'], gateway=cfg['gateway'])
    fields.update({f'adv{i}': cfg['advertise'][i] for i in range(4)})
    if args.dhcp is not None:
        fields['dhcp'] = int(args.dhcp == 'on')
    for field in ['ip', 'netmask', 'gateway']:
        if getattr(args, field) is not None:
            fields[field] = getattr(args, field)
    if args.password:
        password = getpass.getpass('New administrator password: ')
        if not password or len(password.encode('utf-8'))>128 or '\0' in password or password != getpass.getpass('Confirm password: '):
            parser.error('Passwords must match and contain 1–128 UTF-8 bytes without NUL')
        salt = secrets.token_bytes(16)
        fields.update(username=args.username or cfg['username'], salt=salt.hex(),
                      hash=hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, 100000).hex())
        del password
    request = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode('ascii'),
                                     headers={'X-KR260-Request': '1', 'Authorization': authorization,
                                              'Content-Type': 'application/x-www-form-urlencoded'})
    with urllib.request.urlopen(request, timeout=20) as response:
        print(json.dumps(json.load(response), indent=2))
    print('Saved. Restart firmware to apply IP changes.')


if __name__ == '__main__':
    main()
