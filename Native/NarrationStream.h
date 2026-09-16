#pragma once
#include <cstring>

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
