"""Download a CC BY 4.0 speech reference and prepare PCM for the actual Swift DSP.
No third-party audio is added to the source repository. Attribution accompanies
all derived comparison files in the validation artifact.
"""
import array
import hashlib
from pathlib import Path
import struct
import sys
import urllib.request
import wave

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
url = ('https://download.pytorch.org/torchaudio/tutorial-assets/'
       'Lab41-SRI-VOiCES-src-sp0307-ch127535-sg0042.wav')
raw = urllib.request.urlopen(url, timeout=45).read()
source = root / 'voices-reference.wav'
source.write_bytes(raw)
with wave.open(str(source), 'rb') as w:
    assert w.getsampwidth() == 2, 'Expected signed 16-bit reference'
    rate, channels = w.getframerate(), w.getnchannels()
    values = struct.unpack('<' + 'h' * w.getnframes() * channels, w.readframes(w.getnframes()))
mono = [sum(values[i:i+channels]) / (32768 * channels)
        for i in range(0, len(values), channels)]
# The resampling is fixture preparation only, never used by the app.
n = min(720000, round(len(mono) * 48000 / rate))
floats = array.array('f')
for i in range(n):
    p = i * rate / 48000
    a = min(int(p), len(mono) - 1)
    b = min(a + 1, len(mono) - 1)
    floats.append(mono[a] * (1 - (p - a)) + mono[b] * (p - a))
if sys.byteorder != 'little':
    floats.byteswap()
(root / 'input.f32').write_bytes(floats.tobytes())
(root / 'ATTRIBUTION.txt').write_text(
    'Speech: VOiCES, Lab41 / SRI International. CC BY 4.0.\n'
    'Source recording: Lab41-SRI-VOiCES-src-sp0307-ch127535-sg0042.wav\n'
    'Reference: https://iqtlabs.github.io/voices/Lab41-SRI-VOiCES_README/\n'
    'License: https://creativecommons.org/licenses/by/4.0/\n'
    f'Distributed by PyTorch: {url}\n'
    f'Original SHA256: {hashlib.sha256(raw).hexdigest()}\n'
    'Modifications: mono / 48kHz conversion, level matching, and pitch editing.\n'
    'This is an English research speech sample, not the user or their friends.\n'
    '01 = original, 02 = previous wavetable DSP, 03 = source-preserving DSP.\n',
    encoding='utf-8')
print('Reference ready:', n, 'samples')
