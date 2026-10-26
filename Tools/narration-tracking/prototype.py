#!/usr/bin/env python3
"""Offline paragraph TTS -> windowed ASR -> source-position prototype. No app edits."""
import argparse, array, io, json, math, re, selectors, socket
from concurrent.futures import ThreadPoolExecutor
import struct, subprocess, time, urllib.request, wave
from pathlib import Path


def words(text):
    return [(m.group().lower(), m.start(), m.end()) for m in re.finditer(r"[^\W_]+(?:['’][^\W_]+)*", text, re.UNICODE)]


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


def transcribe(port, pcm, offset=0):
    boundary = 'pa3-tracking-prototype'
    body = bytearray()
    fields = {'response_format':'verbose_json','language':'en','temperature':'0', 'temperature_inc':'0'}
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
    if not tokens: raise RuntimeError('Whisper returned no timestamped words: '+str(result)[:300])
    return result,tokens,elapsed


def read_event(process, timeout=180):
    # Unbuffered pipe reads avoid TextIO readline/select buffering mismatches.
    deadline=time.monotonic()+timeout
    data=bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout,selectors.EVENT_READ)
        while time.monotonic()<deadline:
            if not selector.select(max(0,deadline-time.monotonic())): break
            ch=process.stdout.read(1)
            if not ch: raise RuntimeError('Narrator exited; inspect narrator.log')
            if ch==b'\n': return json.loads(data)
            data.extend(ch)
    raise TimeoutError('Narrator event timed out')


def generate(process, fixture, output, on_chunk=None):
    started=time.monotonic()
    request={'id':fixture['id'],'text':' '.join(fixture['sentences']), 'language':'en',
             'path':str(output/(fixture['id']+'.raw')), 'stream':True, 'seed':7, 'pause':.2}
    process.stdin.write((json.dumps(request)+'\n').encode()); process.stdin.flush()
    chunks=[]; data=bytearray()
    while True:
        event=read_event(process)
        if event['event']=='partial':
            chunk=Path(event['path']).read_bytes()
            data.extend(chunk)
            chunks.append({'available':time.monotonic()-started,'audio_end':len(data)/4/24000})
            if on_chunk: on_chunk(bytes(data), started)
        elif event['event']=='audio': break
        elif event['event']=='error': raise RuntimeError(str(event))
    if not data: raise RuntimeError('No generated PCM')
    (output/(fixture['id']+'.pcm')).write_bytes(data)
    (output/(fixture['id']+'.wav')).write_bytes(wav_bytes(data))
    metadata={'chunks':chunks,'generation_seconds':time.monotonic()-started,'duration':len(data)/4/24000}
    (output/(fixture['id']+'-generation.json')).write_text(json.dumps(metadata,indent=2))
    print(f"GENERATED {fixture['id']}: {metadata['duration']:.1f}s audio, {metadata['generation_seconds']:.1f}s generation, first chunk {chunks[0]['available']:.1f}s",flush=True)
    return bytes(data),metadata


def recognize(fixture,pcm,port,output,window=12,stride=4,observations=None):
    text=' '.join(fixture['sentences']); ref=[w[0] for w in words(text)]
    sentence_starts=[]; index=0
    for sentence in fixture['sentences']:
        sentence_starts.append(index); index+=len(words(sentence))
    duration=len(pcm)/4/24000; records=[]; locked={}; cursor=0
    endpoints=list(range(stride,math.ceil(duration),stride))+[duration]
    for endpoint in endpoints:
        start=max(0,endpoint-window)
        if observations is None:
            raw,tokens,elapsed=transcribe(port,pcm[int(start*96000):int(endpoint*96000)],start)
            ready_at=None
        else:
            raw,tokens,elapsed,ready_at=observations[endpoint].result()
        # Only use finalized earlier observations as anchors; never full-clip results.
        anchor=[p['index'] for p in locked.values() if p['start']>=start-0.5]
        lower=max(0,min(anchor)-3) if anchor else max(0,cursor-30)
        # Bound search to near-future text instead of jumping across the document.
        pairs=align(ref,tokens,lower,min(len(ref),cursor+60))
        usable=[p for p in pairs if endpoint==duration or p['end']<=endpoint-0.6]
        confidence=len(pairs)/max(1,len(tokens))
        if confidence>=0.55:
            for pair in usable:
                if pair['index'] not in locked:
                    locked[pair['index']]=dict(pair, audio_available=endpoint)
            if usable: cursor=max(cursor,usable[-1]['index']+1)
        records.append({'start':start,'end':endpoint,'seconds':elapsed,'text':raw.get('text',''),
                        'confidence':confidence,'pairs':pairs,'cursor':cursor,'ready_at':ready_at})
        (output/(fixture['id']+f'-window-{len(records):02}.json')).write_text(json.dumps(raw,indent=2))
        print(f"ASR {fixture['id']} {start:.1f}-{endpoint:.1f}s: {elapsed:.2f}s, matches {len(pairs)}/{len(tokens)}, position {cursor}/{len(ref)}",flush=True)
    # Full-clip ASR is only an offline comparison, NOT ground-truth timing.
    raw,full,full_time=transcribe(port,pcm)
    (output/(fixture['id']+'-full.json')).write_text(json.dumps(raw,indent=2))
    full_pairs=align(ref,full)
    full_by_index={p['index']:p for p in full_pairs}
    boundaries=[]
    for n,idx in enumerate(sentence_starts):
        observed=next((locked[k] for k in range(idx,min(idx+3,len(ref))) if k in locked),None)
        comparison=full_by_index.get(observed['index']) if observed else None
        boundaries.append({'sentence':n,'word_index':idx,'observed':observed,'offline_comparison':comparison})
    return {'text':text,'sentences':fixture['sentences'],'sentence_starts':sentence_starts,
            'windows':records,'words':list(sorted(locked.values(),key=lambda p:p['index'])),
            'boundaries':boundaries,'matched_fraction':len(locked)/len(ref),'full_seconds':full_time,
            'full_matched_fraction':len(full_pairs)/len(ref),'reference_words':len(ref)}


def render(results,output):
    display=[]
    for result in results:
        tokens=words(result['text'])
        item=dict(result)
        item['display_prefix']=result['text'][:tokens[0][1]] if tokens else result['text']
        item['display_words']=[result['text'][token[1]:tokens[i+1][1] if i+1<len(tokens) else len(result['text'])]
                               for i,token in enumerate(tokens)]
        display.append(item)
    payload=json.dumps(display).replace('</','<\\/')
    template=Path(__file__).with_name('demo.html').read_text()
    (output/'index.html').write_text(template.replace('PAYLOAD',payload))
    (output/'highlight.js').write_text(Path(__file__).with_name('highlight.js').read_text())


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--reuse-audio',action='store_true');parser.add_argument('--only')
    parser.add_argument('--concurrent',action='store_true',help='Run windowed ASR as TTS chunks arrive, measuring actual contention')
    args=parser.parse_args()
    if args.concurrent and args.reuse_audio: parser.error('--concurrent requires live generation')
    output=args.output.resolve();output.mkdir(parents=True,exist_ok=True)
    root=Path(__file__).resolve().parents[2];models=Path.home()/'Library/Application Support/PA3/models'
    fixtures=json.loads(Path(__file__).with_name('fixtures.json').read_text())
    if args.only: fixtures=[f for f in fixtures if f['id']==args.only]
    children=[];logs=[];results=[]
    try:
        # Reserve a loopback port for our private server. Nothing is sent externally.
        with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        log=open(output/'whisper.log','wb');logs.append(log)
        server=subprocess.Popen(['/opt/homebrew/bin/whisper-server','-m',str(models/'whisper.ggml'),
            '--host','127.0.0.1','--port',str(port),'-ml','1','-sow','-l','en','-nf','-t','4'],stdout=log,stderr=log);children.append(server)
        for _ in range(240):
            if server.poll() is not None: raise RuntimeError('Whisper failed; inspect whisper.log')
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/',timeout=1): break
            except Exception: time.sleep(.25)
        else: raise TimeoutError('Whisper startup timeout')
        narrator=None
        if not args.reuse_audio:
            log=open(output/'narrator.log','wb');logs.append(log)
            narrator=subprocess.Popen([str(root/'.build/native/pa3-narrator'),
                str(models/'qwen3-tts/Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf'),
                str(models/'qwen3-tts/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf'),str(root/'Resources/Voices/vctk-p311.wav')],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,bufsize=0);children.append(narrator)
            if read_event(narrator)['event']!='ready':raise RuntimeError('Narrator not ready')
        for fixture in fixtures:
            if args.reuse_audio:
                pcm=(output/(fixture['id']+'.pcm')).read_bytes()
                metadata=json.loads((output/(fixture['id']+'-generation.json')).read_text())
            elif args.concurrent:
                futures={}; origin=[None]; next_end=[4]
                with ThreadPoolExecutor(max_workers=1) as executor:
                    def submit_window(data, end):
                        start=max(0,end-12)
                        clip=data[int(start*96000):int(end*96000)]
                        def work():
                            raw,tokens,elapsed=transcribe(port,clip,start)
                            return raw,tokens,elapsed,time.monotonic()-origin[0]
                        futures[end]=executor.submit(work)
                    def on_chunk(data, started):
                        origin[0]=started
                        duration=len(data)/96000
                        while next_end[0] <= duration:
                            submit_window(data,next_end[0]);next_end[0]+=4
                    pcm,metadata=generate(narrator,fixture,output,on_chunk)
                    if metadata['duration'] not in futures: submit_window(pcm,metadata['duration'])
                result=recognize(fixture,pcm,port,output,observations=futures)
            else: pcm,metadata=generate(narrator,fixture,output)
            if not args.concurrent: result=recognize(fixture,pcm,port,output)
            result.update(metadata,id=fixture['id'])
            result['asr_seconds']=sum(w['seconds'] for w in result['windows'])
            # Replay actual chunk arrivals with measured sequential ASR time. This does
            # not measure simultaneous Qwen+Whisper contention or promise zero stalls.
            available=0;needed=0
            for w in result['windows']:
                arrival=next(c['available'] for c in metadata['chunks'] if c['audio_end']+0.001>=w['end'])
                available=w['ready_at'] if w['ready_at'] is not None else max(available,arrival)+w['seconds']
                for boundary in result['boundaries']:
                    p=boundary['observed']
                    if p and p['audio_available']==w['end']:
                        p['simulated_ready']=available
                        needed=max(needed,available-p['start'])
            audio_cursor=0
            for chunk in metadata['chunks']:
                needed=max(needed,chunk['available']-audio_cursor)
                audio_cursor=chunk['audio_end']
            result['simulated_start_buffer']=needed
            result['concurrent']=args.concurrent
            result['simulation_note']=('Actual concurrent TTS+ASR completion times.' if args.concurrent else 'Sequential ASR replay using observed TTS arrivals; concurrent GPU contention not measured.') + ' Playback was not started; buffer is calculated, boundary times are estimates.'
            results.append(result)
            (output/'results.json').write_text(json.dumps(results,indent=2));render(results,output)
        print('REPORT '+str(output/'index.html'),flush=True)
    finally:
        for child in reversed(children):
            child.terminate()
            try:child.wait(timeout=10)
            except subprocess.TimeoutExpired:child.kill();child.wait()
        for log in logs:log.close()

if __name__=='__main__':main()
