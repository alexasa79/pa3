(() => {
  // Streaming waveform-similarity overlap/add. Move analysis windows through
  // the input at the requested speed; keep the samples inside each window intact.
  class TimeStretch {
    constructor(rate) {
      if (!Number.isFinite(rate) || rate < 0.5 || rate > 2) throw new Error('Invalid playback rate');
      this.rate = rate;
      this.hop = 480; // 20 ms at 24 kHz, with a 40 ms window and 10 ms search.
      this.search = 240;
      this.input = new Float32Array(0);
      this.base = 0;
      this.received = 0;
      this.produced = 0;
      this.tail = null;
    }
    push(pcm, final = false) {
      if (this.rate === 1) return pcm;
      const input = new Float32Array(this.input.length + pcm.length);
      input.set(this.input); input.set(pcm, this.input.length);
      this.input = input;
      this.received += pcm.length;
      const output = [];
      const target = Math.round(this.received / this.rate);
      const sample = i => this.input[i - this.base] ?? 0;
      while (this.produced < target) {
        const expected = Math.round(this.produced * this.rate);
        if (!final && expected + this.search + 2 * this.hop > this.received) break;
        let chosen = expected;
        if (this.tail) {
          let best = -Infinity;
          const low = Math.max(this.base, expected - this.search);
          const high = Math.min(expected + this.search, this.received - this.hop);
          for (let candidate = low; candidate <= high; candidate += 3) {
            let correlation = 0, energy = 1e-12;
            for (let j = 0; j < this.hop; j += 4) {
              const x = sample(candidate + j);
              correlation += this.tail[j] * x; energy += x * x;
            }
            const score = correlation / Math.sqrt(energy) - Math.abs(candidate - expected) * 1e-7;
            if (score > best) { best = score; chosen = candidate; }
          }
        }
        const count = Math.min(this.hop, target - this.produced);
        const block = new Float32Array(count);
        for (let j = 0; j < count; j++) {
          const mix = j / this.hop;
          block[j] = this.tail ? this.tail[j] * (1 - mix) + sample(chosen + j) * mix : sample(chosen + j);
        }
        this.tail = Float32Array.from({length:this.hop}, (_, j) => sample(chosen + this.hop + j));
        output.push(block); this.produced += count;
      }
      const drop = Math.max(0, Math.min(this.input.length, Math.round(this.produced * this.rate) - this.search - this.base));
      this.input = this.input.slice(drop); this.base += drop;
      const result = new Float32Array(output.reduce((n, block) => n + block.length, 0));
      let offset = 0;
      for (const block of output) { result.set(block, offset); offset += block.length; }
      if (final) { this.input = new Float32Array(0); this.tail = null; }
      return result;
    }
  }
  const api = {TimeStretch};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  globalThis.ReedahTimeStretch = api;
})();
