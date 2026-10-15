(() => {
  const {TimeStretch} = typeof module !== 'undefined' && module.exports ? require('./time_stretch') : globalThis.ReedahTimeStretch;
  class AudioBudget {
    constructor(limit = 32 * 1024 * 1024) { this.limit = limit; this.used = 0; }
    reserve(bytes) {
      if (this.used + bytes > this.limit) throw new Error('Narration audio memory limit exceeded');
      this.used += bytes;
    }
    release(bytes) { this.used -= bytes; }
  }
  const sharedBudget = new AudioBudget();
  let sharedContext;
  function context() {
    if (!sharedContext) sharedContext = new AudioContext();
    return sharedContext;
  }
  function unlock() { return context().resume(); }

  // One continuous passage. Retain PCM so sentence controls can seek by word time.
  class StreamAudio {
    constructor({getContext = context, estimatedDuration = 1, sourceLength = null, sentenceRanges = [], playbackRate = 1, budget = sharedBudget} = {}) {
      this.getContext = getContext;
      this.estimatedDuration = Math.max(1, estimatedDuration);
      this.wordTimings = [];
      this.sourceLength = sourceLength;
      this.sentenceRanges = sentenceRanges;
      this.buffers = [];
      this.sources = [];
      this.offset = 0;
      this.playing = false;
      this.finished = false;
      this.disposed = false;
      this.playbackRate = playbackRate;
      this.budget = budget;
      this.retainedBytes = 0;
      this.chunkCount = 0;
      this.outputSamples = 0;
      this.stretcher = null;
      this.waiting = false;
      this.total = 0;
      this.generation = 0;
      this.progressValue = 0;
      this.src = '';
    }
    get duration() { return this.total; }
    set playbackRate(rate) {
      if (!Number.isFinite(rate) || rate < 0.5 || rate > 2) throw new Error('Invalid playback rate');
      if (this.stretcher && rate !== this._rate) throw new Error('Cannot change speed during a sentence');
      this._rate = rate;
    }
    get playbackRate() { return this._rate; }
    get currentTime() {
      if (!this.playing || !this.ctx) return this.offset;
      const now = this.ctx.currentTime;
      for (const source of this.sources) {
        if (now < source.when) return source.start;
        if (now < source.when + (source.end - source.start) / this.playbackRate) {
          return source.start + (now - source.when) * this.playbackRate;
        }
      }
      return this.sources.at(-1)?.end ?? this.offset;
    }
    get progress() {
      const fraction = this.currentTime / (this.finished ? Math.max(this.total, 0.001) : Math.max(this.estimatedDuration, this.total));
      this.progressValue = Math.max(this.progressValue, Math.min(this.finished ? 1 : 0.95, fraction));
      return this.progressValue;
    }
    get focusRange() {
      const words = this.wordTimings;
      if (!words.length) return null;
      let current = 0;
      while (current + 1 < words.length && words[current + 1].start <= this.currentTime) current++;
      // Timings are approximate, but source sentence boundaries are known.
      // Restart each three-word group at the sentence (or seek) boundary, and
      // hold the last group through a pause until the next timed word begins.
      const sentence = this.sentenceRanges.find(range =>
        words[current].location >= range.start && words[current].location < range.end);
      const sentenceFloor = sentence ? words.findIndex(word => word.location >= sentence.start) : 0;
      const floor = Math.max(this.focusFloor ?? 0, sentenceFloor);
      const from = floor + Math.floor(Math.max(0, current - floor) / 3) * 3;
      const group = words.slice(from, from + 3).filter(word => !sentence || word.location < sentence.end);
      return {start:group[0].location,
        end:Math.min(sentence?.end ?? Infinity, Math.max(...group.map(w => w.location + w.length)))};
    }
    get currentSourceLocation() {
      const time = this.currentTime;
      const word = this.wordTimings.findLast(word => word.start <= time) ?? this.wordTimings[0];
      return word?.location ?? 0;
    }
    appendTimings(timings, duration) {
      if (!Array.isArray(timings)) throw new Error('Missing narration word timings');
      let previous = this.wordTimings.at(-1);
      for (const word of timings) {
        if (!Number.isInteger(word.location) || !Number.isInteger(word.length) || word.location < 0 || word.length <= 0 ||
            word.location + word.length > this.sourceLength || !Number.isFinite(word.start) || !Number.isFinite(word.end) ||
            word.start < (previous?.start ?? 0) || word.end < word.start || word.end > duration + 0.001 ||
            (previous && word.location < previous.location)) throw new Error('Invalid narration word timing');
        // Several pronounced words can refer to one dictionary term in the document.
        if (previous && word.location === previous.location && word.length === previous.length) {
          previous.end = Math.max(previous.end, word.end);
        } else { this.wordTimings.push({...word}); previous = this.wordTimings.at(-1); }
      }
      if (!this.wordTimings.length) throw new Error('Narration recognition returned no word timings');
    }
    append(message) {
      if (this.disposed || this.finished) throw new Error('Audio received after stream closed');
      if (message.pieceIndex !== this.chunkCount || message.sampleRate !== 24000 ||
          !Number.isInteger(message.samples) || message.samples <= 0 || message.samples > 192000) {
        throw new Error('Invalid or out-of-order PCM chunk');
      }
      const binary = atob(message.audioBase64);
      if (binary.length !== message.samples * 4) throw new Error('Truncated PCM chunk');
      const bytes = Uint8Array.from(binary, ch => ch.charCodeAt(0));
      const view = new DataView(bytes.buffer);
      const pcm = new Float32Array(message.samples);
      for (let i = 0; i < pcm.length; i++) {
        pcm[i] = view.getFloat32(i * 4, true);
        if (!Number.isFinite(pcm[i])) throw new Error('Invalid PCM sample');
      }
      if (this.total + pcm.length / message.sampleRate > 350) throw new Error('Sentence audio exceeds limit');
      if (this.sourceLength !== null) this.appendTimings(message.wordTimings, this.total + pcm.length / message.sampleRate);
      this.stretcher ??= new TimeStretch(this.playbackRate);
      this.total += pcm.length / message.sampleRate;
      this.chunkCount++;
      this.store(this.stretcher.push(pcm));
      this.schedule();
    }
    store(pcm) {
      if (!pcm.length) return;
      this.budget.reserve(pcm.byteLength);
      this.retainedBytes += pcm.byteLength;
      const start = this.outputSamples / 24000 * this.playbackRate;
      this.outputSamples += pcm.length;
      this.buffers.push({pcm, rate:24000, start, end:this.outputSamples / 24000 * this.playbackRate});
    }
    finish(count) {
      if (this.disposed || this.finished || count !== this.chunkCount || count === 0) throw new Error('Incomplete audio stream');
      this.store(this.stretcher.push(new Float32Array(0), true));
      this.finished = true;
      this.schedule();
      this.checkEnded();
    }
    async play() {
      if (this.disposed) throw new Error('Audio stream disposed');
      if (this.playing) return;
      if (!(this.playbackRate >= 0.5 && this.playbackRate <= 2)) throw new Error('Invalid playback rate');
      const generation = ++this.generation;
      this.ctx = this.getContext();
      this.contextChanged ??= () => {
        if (!this.playing) return;
        if (this.ctx.state === 'closed') {
          this.error = {message:'Audio output closed'};
          this.onerror?.();
        } else if (this.ctx.state !== 'running') {
          this.waiting = true;
          this.onwaiting?.();
        } else if (this.sources.some(s => !s.ended)) {
          this.waiting = false;
          this.onplaying?.();
        }
      };
      this.ctx.addEventListener?.('statechange', this.contextChanged);
      await this.ctx.resume();
      if (generation !== this.generation || this.disposed) return;
      this.playing = true;
      this.schedule();
      this.checkEnded();
    }
    schedule() {
      if (!this.playing || this.disposed) return;
      let cursor = this.sources.at(-1)?.end ?? this.offset;
      let when = this.sources.length ? this.sources.at(-1).when + this.sources.at(-1).duration : this.ctx.currentTime + 0.04;
      if (this.sources.length && this.total > cursor && this.ctx.currentTime - when > 0.05) {
        console.warn("PA3 extension: Audio buffer underrun", {
          gapSeconds: Number((this.ctx.currentTime - when).toFixed(3)),
          playbackRate: this.playbackRate,
          bufferedAudioSeconds: Number((this.total - cursor).toFixed(3))
        });
      }
      when = Math.max(when, this.ctx.currentTime);
      const generation = this.generation;
      for (const chunk of this.buffers) {
        if (chunk.end <= cursor + 1e-8) continue;
        this.budget.reserve(chunk.pcm.byteLength);
        let node;
        try {
          const buffer = this.ctx.createBuffer(1, chunk.pcm.length, chunk.rate);
          buffer.copyToChannel(chunk.pcm, 0);
          node = this.ctx.createBufferSource();
          node.buffer = buffer;
          node.playbackRate.value = 1; // Time stretching preserves pitch before scheduling.
          node.connect(this.ctx.destination);
        } catch (error) {
          node?.disconnect();
          this.budget.release(chunk.pcm.byteLength);
          throw error;
        }
        // Seeking through time-stretched chunks must use integral output sample
        // offsets; floating-point division can otherwise repeat/drop a sample.
        const offsetSamples = Math.round(Math.max(0, cursor - chunk.start) / this.playbackRate * chunk.rate);
        const duration = (chunk.pcm.length - offsetSamples) / chunk.rate;
        const clockRate = this.ctx.sampleRate ?? chunk.rate;
        when = Math.round(when * clockRate) / clockRate;
        const endWhen = Math.round((when + duration) * clockRate) / clockRate;
        const entry = {node, when, start:cursor, end:chunk.end, duration, ended:false, bytes:chunk.pcm.byteLength};
        this.sources.push(entry);
        node.onended = () => {
          if (generation !== this.generation) return;
          entry.ended = true;
          this.releaseSource(entry);
          this.checkEnded();
          if (this.playing && !this.finished && this.sources.every(s => s.ended)) {
            this.waiting = true;
            this.onwaiting?.();
          }
        };
        node.start(when, offsetSamples / chunk.rate);
        node.stop(endWhen);
        if (this.sources.length === 1 || this.waiting) {
          this.waiting = false;
          setTimeout(() => {
            if (generation === this.generation && this.playing) this.onplaying?.();
          }, Math.max(0, when - this.ctx.currentTime) * 1000);
        }
        when = endWhen;
        cursor = chunk.end;
      }
    }
    releaseSource(source) {
      source.node.disconnect();
      source.node.buffer = null;
      this.budget.release(source.bytes);
      source.bytes = 0;
    }
    checkEnded() {
      const consumed = this.sources.length ? this.sources.every(s => s.ended) : this.offset >= this.total - 1 / 24000;
      if (this.playing && this.finished && consumed) {
        this.offset = this.total;
        this.playing = false;
        this.ctx?.removeEventListener?.('statechange', this.contextChanged);
        this.sources = [];
        this.onended?.();
      }
    }
    pause() {
      this.offset = this.currentTime;
      this.playing = false;
      this.ctx?.removeEventListener?.('statechange', this.contextChanged);
      ++this.generation;
      for (const source of this.sources) {
        source.node.onended = null;
        source.node.stop();
        this.releaseSource(source);
      }
      this.sources = [];
    }
    seek(seconds) {
      if (this.disposed) throw new Error('Audio stream disposed');
      if (!Number.isFinite(seconds) || seconds < 0 || seconds > this.total) throw new Error('Invalid audio seek position');
      this.pause();
      this.offset = seconds;
      this.focusFloor = Math.max(0, this.wordTimings.findLastIndex(word => word.start <= seconds));
      this.progressValue = 0;
      this.waiting = false;
    }
    rewind() { this.seek(0); }
    dispose() {
      this.pause(); this.disposed = true; this.buffers = []; this.stretcher = null;
      this.budget.release(this.retainedBytes); this.retainedBytes = 0;
      this.onended = this.onplaying = this.onwaiting = null;
    }
  }
  const api = {StreamAudio, AudioBudget, unlock};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  globalThis.ReedahStreamAudio = api;
})();
