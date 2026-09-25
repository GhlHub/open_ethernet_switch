"""Exercise the host helper without touching a board or logging passwords."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
from unittest import mock
import urllib.parse

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('configure_switch', Path(__file__).resolve().parents[3] / 'scripts/configure_switch.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = dict(admin=31, sfp=0, dhcp=True, ip='0.0.0.0', netmask='0.0.0.0', gateway='0.0.0.0',
              username='admin', advertise=[4,7,3,7])
requests = []
def urlopen(request, **_):
    requests.append(request)
    return io.BytesIO(json.dumps(config).encode())

def run(args):
    requests.clear()
    with mock.patch.object(sys, 'argv', ['configure_switch.py', *args]), \
         mock.patch.object(module.urllib.request, 'urlopen', urlopen), \
         contextlib.redirect_stdout(io.StringIO()) as output:
        module.main()
    return output.getvalue()

run([])
assert len(requests) == 1
with mock.patch.object(module.getpass, 'getpass', return_value='test-only-password'), \
     mock.patch.object(module.secrets, 'token_bytes', return_value=b'0123456789abcdef'):
    output = run(['--username', 'operator', '--password', '--dhcp', 'off', '--ip', '10.0.1.215',
                  '--netmask', '255.255.255.0', '--gateway', '10.0.1.1'])
assert len(requests) == 2
form = urllib.parse.parse_qs(requests[1].data.decode())
assert form['username'] == ['operator'] and form['dhcp'] == ['0'] and form['ip'] == ['10.0.1.215']
assert form['adv2'] == ['3'] and form['mask'] == ['31']
assert form['hash'] == [hashlib.pbkdf2_hmac('sha256', b'test-only-password', b'0123456789abcdef', 100000).hex()]
assert requests[1].get_header('Authorization').startswith('Basic ')
assert 'test-only-password' not in output and 'test-only-password' not in requests[1].data.decode()
assert requests[1].get_header('X-kr260-request') == '1'
print('PASS: helper read-only mode, settings preservation, static IPv4 and locally derived credential update')
