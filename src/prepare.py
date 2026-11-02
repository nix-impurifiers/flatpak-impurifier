# SPDX-License-Identifier: MIT
import argparse
import os
import pwd
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--owner', help='prepare a user installation as root without running application code')
parser.add_argument('application')
args = parser.parse_args()
if args.owner:
    if os.geteuid() != 0:
        parser.error('--owner requires root')
    owner = pwd.getpwnam(args.owner)
    def drop():
        os.initgroups(owner.pw_name, owner.pw_gid)
        os.setgid(owner.pw_gid)
        os.setuid(owner.pw_uid)
    env = dict(os.environ, HOME=owner.pw_dir, USER=owner.pw_name, LOGNAME=owner.pw_name)
    env.pop('XDG_DATA_HOME', None)
    env.pop('XDG_CONFIG_HOME', None)
else:
    drop = None
    env = os.environ.copy()
def native(*argv):
    return subprocess.check_output(['flatpak', *argv], text=True, env=env, preexec_fn=drop).strip()
app = Path(native('info', '--user', '--show-location', args.application))
runtime_ref = native('info', '--user', '--show-runtime', args.application)
runtime = Path(native('info', '--user', '--show-location', runtime_ref))
with tempfile.TemporaryDirectory(prefix='flatpak-impurifier-') as staging:
    for index, deployment in enumerate([runtime, app]):
        files = deployment / 'files'
        target = os.readlink(files / 'nix-root')
        command = ['nix-store', '--realise', target, '--add-root', f'{staging}/{index}', '--indirect']
        cache = files / 'cache'
        if cache.is_dir():
            command += ['--option', 'substituters', cache.as_uri()]
            if os.geteuid() == 0:
                command += ['--option', 'require-sigs', 'false']
        subprocess.run(command, check=True)
        subprocess.run(['impurifier-register-root', str(files / 'nix-root')], check=True, env=env, preexec_fn=drop)
