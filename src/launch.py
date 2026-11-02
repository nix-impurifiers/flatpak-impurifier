# SPDX-License-Identifier: MIT
import fcntl
import hashlib
import importlib.util
import configparser
import json
import os
import subprocess
import sys
from pathlib import Path

metadata = configparser.ConfigParser()
metadata.read('/.flatpak-info')
config = json.loads(Path('/app/application.json').read_text())
os.environ['PATH'] = config['nixBin'] + ':' + os.environ.get('PATH', '')
helper = config['registerRoot']
for kind, local in [('runtime', '/usr'), ('app', '/app')]:
    host = metadata['Instance'][kind + '-path']
    subprocess.run([helper, host + '/nix-root', local + '/nix-root'], check=True)
program = str(Path('/app/nix-root').resolve() / 'bin' / config['program'])
environment = os.environ.copy()
if config.get('hardware'):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('engine', '/app/engine.py')
    engine = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(engine)
    deployment = metadata['Instance']['app-path']
    state = Path(os.environ['XDG_DATA_HOME']) / 'flatpak-impurifier' / hashlib.sha256(deployment.encode()).hexdigest()
    state.mkdir(parents=True, exist_ok=True)
    (state / 'deployment').write_text(deployment)
    bridge = dict(config['hardware'])
    bridge['libraries'] = {name: '/run/host' + source for name, source in bridge['libraries'].items()}
    manifest = engine.validate({'name': 'flatpak-hardware', 'version': '1', 'priority': 5,
        'installable': str(Path('/app/nix-root').resolve()), 'hardware': bridge}, 'flatpak-impurifier')
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        snapshot = engine.hardware_snapshots([manifest], state)['flatpak-hardware']
        subprocess.run(['nix-store', '--realise', snapshot, '--add-root', str(state / ('library-' + hashlib.sha256(snapshot.encode()).hexdigest())), '--indirect'], check=True, stdout=subprocess.DEVNULL)
    environment['LD_LIBRARY_PATH'] = snapshot + (':' + environment['LD_LIBRARY_PATH'] if environment.get('LD_LIBRARY_PATH') else '')
    if bridge.get('preload'):
        environment['LD_PRELOAD'] = ' '.join(snapshot + '/' + name for name in bridge['preload'])
os.execve(program, [program, *sys.argv[1:]], environment)
