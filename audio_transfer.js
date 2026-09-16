(() => {
  // Native messaging limits each host-to-Chrome message to 1 MiB.
  class Assembler {
    constructor() { this.pending = null; }
    accept(event) {
      if (!Number.isInteger(event.part) || event.part < 0 || typeof event.audioBase64 !== "string" ||
          !/^[A-Za-z0-9+/]*={0,2}$/.test(event.audioBase64) || event.audioBase64.length % 4 !== 0 ||
          typeof event.final !== "boolean") throw new Error("Malformed audio chunk");
      if (event.part === 0) {
        if (this.pending) throw new Error("Overlapping audio transfers");
        this.pending = { id: event.utteranceId, index: event.index, pieceIndex: event.pieceIndex, part: 0, size: 0, chunks: [] };
      }
      const pending = this.pending;
      if (!pending || pending.id !== event.utteranceId || pending.index !== event.index || pending.pieceIndex !== event.pieceIndex ||
          pending.part !== event.part) throw new Error("Out-of-order audio chunk");
      pending.size += event.audioBase64.length;
      if (pending.size > 48 * 1024 * 1024) throw new Error("Audio transfer too large");
      pending.chunks.push(event.audioBase64);
      pending.part++;
      if (!event.final) return null;
      this.pending = null;
      return { ...event, event: "audio", audioBase64: pending.chunks.join(""), mimeType: event.stream ? "application/octet-stream" : "audio/wav" };
    }
  }
  const api = { Assembler };
  if (typeof module !== "undefined") module.exports = api;
  globalThis.ReedahAudioTransfer = api;
})();
