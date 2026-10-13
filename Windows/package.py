"""Build a portable transfer ZIP using only Python's standard library."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--include-mac-data', action='store_true', help='Include locally copied practice backup and recordings.')
args = parser.parse_args()
root = Path(__file__).resolve().parent
repo = root.parent
dest = root / 'dist'
dest.mkdir(exist_ok=True)
source_zip = dest / 'Mac-source-backup.zip'

with ZipFile(source_zip, 'w', ZIP_DEFLATED) as archive:
    candidates = []
    for name in ('DrumTrainer', 'DrumTrainerTests', 'DrumTrainer.xcodeproj', 'docs'):
        candidates.extend((repo / name).rglob('*'))
    candidates.extend(repo.glob('*.md'))
    for path in sorted(candidates):
        if path.is_file() and '.DS_Store' not in path.parts and 'xcuserdata' not in path.parts:
            archive.write(path, Path('DrumTrainer-Mac-source') / path.relative_to(repo))

runtime = ['index.html', 'style.css', 'app.mjs', 'core.mjs', 'native-scoring.mjs', 'audio-core.mjs', 'midi.mjs', 'legacy-data.mjs', 'practice-progress.mjs', 'backup-state.mjs', 'timing-alignment.mjs', 'playback-onset.mjs', 'playback-worklet.mjs', 'playback-capture.mjs', 'portable-zip.mjs', 'timing-timeline.mjs', 'notation.mjs', 'coaching.mjs', 'sound-synthesis.mjs', 'output-worklet.mjs', 'recordings.mjs', 'recording-core.mjs', 'recording-worklet.mjs', 'kick-worklet.mjs', 'Start DrumTrainer.cmd', 'Start-DrumTrainer.ps1', 'README.md']
output = dest / 'DrumTrainer-Windows.zip'
with ZipFile(output, 'w', ZIP_DEFLATED) as archive:
    for name in runtime:
        data = (root / name).read_bytes()
        if name.endswith(('.cmd', '.ps1')):
            data = data.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
        archive.writestr(f'DrumTrainer-Windows/{name}', data)
    archive.write(source_zip, 'DrumTrainer-Windows/Mac-source-backup.zip')
    if args.include_mac_data:
        backup = root / 'Mac-practice-backup.json'
        if backup.exists():
            archive.write(backup, f'DrumTrainer-Windows/{backup.name}')
        for recording in sorted((root / 'Mac-recordings').glob('*.m4a')):
            archive.write(recording, f'DrumTrainer-Windows/Mac-recordings/{recording.name}')
with ZipFile(output) as archive:
    bad = archive.testzip()
    if bad:
        raise RuntimeError(f'ZIP verification failed: {bad}')
print(f'{output}\n{output.stat().st_size / 1024 / 1024:.1f} MB; all ZIP entries verified.')
