#!/usr/bin/env python3
"""Private, local recognition worker. Emits source UTF-16 ranges with audio times."""
import array, io, json, re, socket, subprocess, sys, time, urllib.request, wave, signal
from pathlib import Path

def words(text):
    return [(m.group().lower(), m.start(), m.end()) for m in re.finditer(r"[^\W_]+(?:['’][^\W_]+)*", text, re.UNICODE)]


def join_cost(joined, observed):
    """Allow an ASR word boundary change, with at most one spelling edit."""
    if joined == observed:
        return 0
    if min(len(joined), len(observed)) < 6 or abs(len(joined) - len(observed)) > 1:
        return None
    i = 0
    while i < min(len(joined), len(observed)) and joined[i] == observed[i]:
        i += 1
    if len(joined) == len(observed):
        matches = joined[i+1:] == observed[i+1:]
    elif len(joined) > len(observed):
        matches = joined[i+1:] == observed[i:]
    else:
        matches = joined[i:] == observed[i+1:]
    return .4 if matches else None


def align(reference, recognized, lower=0, upper=None):
    """Monotonic local edit alignment. Free reference prefix/suffix; no future text as ASR prompt."""
    ref = reference[lower:upper]
    hyp = [w['word'] for w in recognized]
    if not ref or not hyp:
        return []
    n, m = len(ref), len(hyp)
    score = [[0] * (n + 1) for _ in range(m + 1)]
    back = [[None] * (n + 1) for _ in range(m + 1)]
    for i in range(1, m + 1):
        score[i][0] = i
        back[i][0] = 'insert'
        for j in range(1, n + 1):
            same = hyp[i-1] == ref[j-1]
            options = [(score[i-1][j-1] + (0 if same else 1.2), 'match'),
                       (score[i-1][j] + 1, 'insert'), (score[i][j-1] + 1, 'delete')]
            source_join = join_cost(ref[j-2] + ref[j-1], hyp[i-1]) if j >= 2 else None
            recognized_join = join_cost(hyp[i-2] + hyp[i-1], ref[j-1]) if i >= 2 else None
            if source_join is not None:
                options.append((score[i-1][j-2] + source_join, 'reference_join'))
            if recognized_join is not None:
                options.append((score[i-2][j-1] + recognized_join, 'recognized_join'))
            score[i][j], back[i][j] = min(options, key=lambda x: x[0])
    # Earliest equally good location prevents jumps to later repeated phrases.
    j = min(range(n + 1), key=lambda j: score[m][j])
    i, pairs = m, []
    while i:
        op = back[i][j]
        if op == 'match':
            if hyp[i-1] == ref[j-1]:
                pairs.append(dict(recognized[i-1], index=lower+j-1))
            i -= 1; j -= 1
        elif op == 'reference_join':
            # ASR may hear "a ranges" as the single word "arranges". Keep both
            # known source words within that observed audio interval; only their
            # internal boundary is estimated, by character proportion.
            token = recognized[i-1]
            duration = token['end'] - token['start']
            fraction = len(ref[j-2]) / (len(ref[j-2]) + len(ref[j-1]))
            split = token['start'] + duration * fraction
            pairs.append(dict(token, word=ref[j-1], index=lower+j-1,
                              start=split, estimated=True, coverage=.5))
            pairs.append(dict(token, word=ref[j-2], index=lower+j-2,
                              end=split, estimated=True, coverage=.5))
            i -= 1; j -= 2
        elif op == 'recognized_join':
            pairs.append(dict(recognized[i-2], word=ref[j-1], index=lower+j-1,
                              end=recognized[i-1]['end'], estimated=True, coverage=2))
            i -= 2; j -= 1
        elif op == 'insert': i -= 1
        else: j -= 1
    return list(reversed(pairs))


def wav_bytes(pcm, rate=24000):
    floats = array.array('f'); floats.frombytes(pcm)
    shorts = array.array('h', (max(-32768, min(32767, round(x * 32767))) for x in floats))
    # Whisper accepts 16 kHz PCM; deterministic linear interpolation from the TTS rate.
    if rate != 16000:
        count = int(len(shorts) * 16000 / rate)
        out = array.array('h')
        for i in range(count):
            at = i * rate / 16000; j = int(at); f = at-j
            out.append(round(shorts[j]*(1-f) + shorts[min(j+1,len(shorts)-1)]*f))
        shorts = out
    out = io.BytesIO()
    with wave.open(out, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(shorts.tobytes())
    return out.getvalue()


def transcribe(port, pcm, offset=0, language="en"):
    boundary = 'pa3-narration-timing'
    body = bytearray()
    fields = {'response_format':'verbose_json','language':language,'temperature':'0', 'temperature_inc':'0'}
    for key, value in fields.items():
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
    body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="clip.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode())
    body.extend(wav_bytes(pcm)); body.extend(f'\r\n--{boundary}--\r\n'.encode())
    request = urllib.request.Request(f'http://127.0.0.1:{port}/inference',data=body,
        headers={'Content-Type':f'multipart/form-data; boundary={boundary}'})
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=120) as response: result=json.load(response)
    elapsed=time.monotonic()-started
    tokens=[]
    for segment in result.get('segments',[]):
        text=segment.get('text','')
        pieces=words(text)
        for k,(word,_,_) in enumerate(pieces):
            # Server -ml 1 -sow normally returns one word per segment.
            # Multiword segments are retained but explicitly marked as estimated.
            start=segment['start']; end=segment['end']
            tokens.append({'word':word,'start':offset+start+(end-start)*k/max(1,len(pieces)),
                'end':offset+start+(end-start)*(k+1)/max(1,len(pieces)), 'estimated':len(pieces)>1})
    return result,tokens,elapsed



class Tracker:
    def __init__(self):
        self.segment = None
        self.locked = {}
        self.cursor = 0
        self.recovering = False

    def update(self, request, recognize):
        if self.segment != request['segment']:
            self.segment = request['segment']
            self.locked = {}
            self.cursor = 0
            self.recovering = False
        pcm = b''.join(Path(path).read_bytes() for path in request['paths'])
        duration = len(pcm) / 96000
        start = 0 if request.get("complete") else max(0, duration - 12)
        _, tokens, _ = recognize(pcm[int(start * 24000) * 4:], start)
        reference = request['words']
        anchors = [index for index, pair in self.locked.items() if pair['start'] >= start - .5]
        lower = max(0, min(anchors) - 3) if anchors else max(0, self.cursor - 30)
        pairs = align([word['text'].replace('’', "'") for word in reference],
                      [dict(token, word=token['word'].replace('’', "'")) for token in tokens],
                      lower, len(reference) if self.recovering or request.get("complete") else min(len(reference), self.cursor + 80))
        if not tokens or sum(pair.get('coverage', 1) for pair in pairs) / len(tokens) < .55:
            # Publish audio with no new timings. Preserve the last reliable source
            # position and try again on the next rolling window, without retries.
            self.recovering = True
            print('Narration alignment uncertain; holding last highlight until recognition recovers', file=sys.stderr, flush=True)
            return []
        self.recovering = False
        added = []
        for pair in pairs:
            index = pair['index']
            if index in self.locked or index < self.cursor:
                continue
            # First observation wins. Keep the display monotonic across overlap windows.
            previous = max((p['start'] for p in self.locked.values()), default=0)
            pair['start'] = min(duration, max(previous, pair['start']))
            pair['end'] = min(duration, max(pair['start'], pair['end']))
            self.locked[index] = pair
            added.append(dict(location=reference[index]['location'], length=reference[index]['length'],
                              start=request['offset'] + pair['start'], end=request['offset'] + pair['end']))
        if pairs:
            self.cursor = max(self.cursor, pairs[-1]['index'] + 1)
        return added


def main():
    server = None
    def stop(signum, frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    try:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        server = subprocess.Popen([sys.argv[1], '-m', sys.argv[2], '--host', '127.0.0.1',
            '--port', str(port), '-ml', '1', '-sow', '-l', sys.argv[3], '-nf', '-t', '4'],
            stdout=sys.stderr, stderr=sys.stderr)
        for _ in range(240):
            if server.poll() is not None:
                raise RuntimeError('Narration recognition server exited during startup')
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=1): break
            except OSError: time.sleep(.25)
        else: raise TimeoutError('Narration recognition startup timed out')
        tracker = Tracker()
        for line in sys.stdin:
            request = json.loads(line)
            timings = tracker.update(request, lambda pcm, offset: transcribe(port, pcm, offset, request['language']))
            print(json.dumps(dict(id=request['id'], chunk=request['chunk'], words=timings)), flush=True)
    except Exception as error:
        print(json.dumps(dict(error=str(error))), flush=True)
        return 1
    finally:
        if server is not None:
            server.terminate()
            try: server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
    return 0

if __name__ == '__main__':
    sys.exit(main())
