#include "NarrationStream.h"
#include <llama.h>
#include <mtmd.h>
#include <ggml-backend.h>
#include <vector>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <algorithm>

static void check(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static std::vector<float> decode(mtmd_context *audio, const std::vector<int32_t> &codes, int window, bool policy) {
    std::vector<float> result;
    std::vector<char> state;
    const int frames = (int)codes.size() / 16;
    int start = 0;
    for (int end = 1; end <= frames; ++end) {
        const bool final = end == frames;
        if (!(policy ? narrationCanPublish(end, final) : (end % window == 0 || final))) continue;
        mtmd_gen_inp input = mtmd_gen_inp_default(audio);
        input.type = MTMD_GEN_PROCESS_TYPE_GEN_WAV;
        input.codes = const_cast<int32_t *>(codes.data() + start * 16);
        input.n_codes = (end - start) * 16;
        input.state_data = state.empty() ? nullptr : state.data();
        input.state_size = state.size();
        input.seed = 7;
        mtmd_gen_out output{};
        check(mtmd_gen_audio_process(audio, &input, &output) == 0, "PCM decoding failed");
        result.insert(result.end(), output.audio, output.audio + output.n_samples);
        state.assign(output.state_data, output.state_data + output.state_size);
        start = end;
    }
    return result;
}
static double rms(const std::vector<float> &a, const std::vector<float> &b, size_t start, size_t end) {
    double sum = 0;
    for (size_t i = start; i < end; ++i) {
        check(std::isfinite(a[i]) && std::isfinite(b[i]), "Nonfinite PCM");
        const double difference = a[i] - b[i];
        sum += difference * difference;
    }
    return std::sqrt(sum / (end - start));
}
int main(int argc, char **argv) {
    try {
        check(narrationDecoderSupported("0.4.1") && !narrationDecoderSupported("0.4.2") && !narrationDecoderSupported(nullptr), "Decoder compatibility guard failed");
        check(narrationDecoderSupported(llama_version()), "Installed llama.cpp version has not been validated for streaming");
        // These boundaries must stay safe even if the latency policy changes.
        for (int i = 1; i < 72; ++i) check(!narrationCanPublish(i), "Premature padded decoder flush");
        check(narrationCanPublish(72) && narrationCanPublish(144) && narrationCanPublish(155, true), "Missing safe decoder flush");
        std::vector<float> speech(2400, 0.1f);
        check(narrationPausePadding(speech.data(), speech.size(), 24000, .20) == 4800, "Missing sentence pause after speech");
        speech.resize(3600, 0);
        check(narrationPausePadding(speech.data(), speech.size(), 24000, .20) == 3600, "Existing trailing silence must count toward the pause");
        speech.resize(9600, 0);
        check(narrationPausePadding(speech.data(), speech.size(), 24000, .20) == 0, "Long natural pauses must remain intact without extra padding");
        check(narrationPausePadding(speech.data(), speech.size(), 24000, 0) == 0, "Zero pause must not add samples");
        speech.back() = .1f;
        check(narrationPausePadding(speech.data(), speech.size(), 24000, .20) == 4800, "Interior silence must not substitute for the final pause");
        speech.resize(9601, .1f);
        check(narrationPausePadding(speech.data(), speech.size(), 24000, .20) == 4800, "Final partial acoustic window must retain speech before padding");
        if (argc == 1) { puts("PASS decoder window publication boundaries and streamed sentence pause padding"); return 0; }
        check(argc == 3, "Use: narration-stream-test [model.gguf projector.gguf]");
        ggml_backend_load_all(); llama_backend_init();
        auto mp = llama_model_default_params(); mp.n_gpu_layers = 99;
        auto *model = llama_model_load_from_file(argv[1], mp); check(model, "Model load failed");
        auto ap = mtmd_context_params_default(); ap.use_gpu = true;
        auto *audio = mtmd_init_from_file(argv[2], model, ap); check(audio, "Audio model load failed");
        // Identical deterministic codec frames isolate waveform state from model sampling.
        // Two complete windows followed by a short final tail exercise every boundary.
        std::vector<int32_t> codes(155 * 16);
        for (size_t i = 0; i < codes.size(); ++i) codes[i] = (int32_t)((i * 37 + i / 16) % 128);
        auto reference = decode(audio, codes, 72, false);
        auto streamed = decode(audio, codes, 72, true);
        auto premature = decode(audio, codes, 16, false);
        check(reference.size() == streamed.size() && reference.size() == premature.size(), "PCM length changed");
        const double correctError = rms(reference, streamed, 0, reference.size());
        const size_t firstBlock = 16 * (reference.size() / 155);
        const double oldPrefixError = rms(reference, premature, 0, firstBlock);
        const double oldLaterError = rms(reference, premature, firstBlock, reference.size());
        printf("Decoder PCM RMS difference: corrected=%g, old first block=%g, old later blocks=%g\n", correctError, oldPrefixError, oldLaterError);
        check(correctError < 1e-5, "Streamed decoder state differs from complete-window reference");
        check(oldLaterError > correctError * 10 + 1e-6, "Regression fixture did not expose short-window corruption");
        mtmd_free(audio); llama_model_free(model); llama_backend_free();
        puts("PASS streamed waveform matches full-window decoding; premature flush reproduces corruption");
        return 0;
    } catch (const std::exception &error) { fprintf(stderr, "FAIL: %s\n", error.what()); return 1; }
}
