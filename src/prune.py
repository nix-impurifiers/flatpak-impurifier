# SPDX-License-Identifier: MIT
import shutil
from pathlib import Path

for state in (Path.home() / '.var/app').glob('*/data/flatpak-impurifier/*'):
    deployment = state / 'deployment'
    if deployment.is_file() and not Path(deployment.read_text()).exists():
        shutil.rmtree(state)
