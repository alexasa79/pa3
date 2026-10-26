#pragma once
#include <cstring>
#include <algorithm>
#include <cmath>
#include <cstddef>

// llama.cpp 0.4.1 Qwen code2wav pads every call to 72 frames and advances
// its state by that entire window. A partial window is safe only at EOS.
// See tools/mtmd/clip.cpp (GEN_WAV) and mtmd-helper-gen.cpp (window_frames).
constexpr int qwenDecoderWindowFrames = 72;
inline bool narrationDecoderSupported(const char *version) {
    return version && std::strcmp(version, "0.4.1") == 0;
}
constexpr bool narrationCanPublish(int frames, bool final = false) {
    return final || (frames > 0 && frames % qwenDecoderWindowFrames == 0);
}

// Top up only the final trailing silence. Never cut speech or alter decoder joins.
inline size_t narrationPausePadding(const float *pcm, size_t count, int rate, double pause) {
    const size_t target = static_cast<size_t>(std::ceil(pause * rate));
    const size_t window = std::max(1, rate / 100);
    size_t end = count;
    while (end > 0) {
        const size_t start = (end - 1) / window * window;
        double energy = 0;
        for (size_t i = start; i < end; ++i) energy += pcm[i] * pcm[i];
        if (energy / (end - start) > 0.0000032) break;
        end = start;
    }
    const size_t trailing = count - end;
    return trailing < target ? target - trailing : 0;
}
