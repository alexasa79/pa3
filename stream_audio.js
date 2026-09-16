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

  // One continuous sentence. Retain its PCM for pause/resume and sentence replay.
  class StreamAudio {
    constructor({getContext = context, estimatedDuration = 1, playbackRate = 1, budget = sharedBudget} = {}) {
      this.getContext = getContext;
      this.estimatedDuration = Math.max(1, estimatedDuration);
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
      let when = this.sources.length ? this.sources.at(-1).when + (this.sources.at(-1).end - this.sources.at(-1).start) / this.playbackRate : this.ctx.currentTime + 0.04;
      if (this.sources.length && this.total > cursor && this.ctx.currentTime - when > 0.05) {
        console.warn("Reedah: Audio buffer underrun", {
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
        const entry = {node, when, start:cursor, end:chunk.end, ended:false, bytes:chunk.pcm.byteLength};
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
        node.start(when, Math.max(0, cursor - chunk.start) / this.playbackRate);
        if (this.sources.length === 1 || this.waiting) {
          this.waiting = false;
          setTimeout(() => {
            if (generation === this.generation && this.playing) this.onplaying?.();
          }, Math.max(0, when - this.ctx.currentTime) * 1000);
        }
        when += (chunk.end - cursor) / this.playbackRate;
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
    rewind() { this.pause(); this.offset = 0; this.progressValue = 0; }
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
