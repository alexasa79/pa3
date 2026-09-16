// Persistent Qwen worker using the public APIs supplied by Homebrew llama.cpp.
// The private stdin/stdout protocol is one JSON object per line; diagnostics use stderr.
#import <Foundation/Foundation.h>
#include <llama.h>
#include <mtmd.h>
#include <mtmd-helper.h>
#include <ggml-backend.h>
#include <iostream>
#include <stdexcept>
#include <vector>
#include <limits>
#include <cmath>
#include <algorithm>
#include "NarrationStream.h"

static void emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}
static void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}
static void logMessage(ggml_log_level level, const char *text, void *) {
    if (level >= GGML_LOG_LEVEL_INFO) fputs(text, stderr);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        try {
            require(argc == 4, "Expected model, projector and speaker WAV paths");
            require(narrationDecoderSupported(llama_version()),
                    "Unsupported llama.cpp version. PA3 streaming requires tested llama.cpp 0.4.1; validate the decoder before upgrading.");
            llama_log_set(logMessage, nullptr);
            mtmd_helper_log_set(logMessage, nullptr);
            ggml_backend_load_all();
            llama_backend_init();
            auto mp = llama_model_default_params();
            mp.n_gpu_layers = 99;
            llama_model *model = llama_model_load_from_file(argv[1], mp);
            require(model, "Could not load Qwen model");
            // Match llama.cpp's common sampler: the model forbids these codec tokens.
            const auto *vocab = llama_model_get_vocab(model);
            int32_t suppressedCount = 0;
            const auto *suppressed = llama_vocab_get_suppress_tokens(vocab, &suppressedCount);
            std::vector<llama_logit_bias> biases;
            for (int32_t i = 0; i < suppressedCount; ++i) {
                biases.push_back({suppressed[i], -std::numeric_limits<float>::infinity()});
            }
            auto cp = llama_context_default_params();
            cp.n_ctx = 4096;
            cp.n_batch = 512;
            cp.n_ubatch = 512;
            cp.n_threads = cp.n_threads_batch = 8;
            cp.embeddings = true;
            llama_context *ctx = llama_init_from_model(model, cp);
            require(ctx, "Could not create Qwen context");
            auto ap = mtmd_context_params_default();
            ap.use_gpu = true;
            mtmd_context *audio = mtmd_init_from_file(argv[2], model, ap);
            require(audio, "Could not load Qwen audio model");
            auto speaker = mtmd_helper_bitmap_init_from_file(audio, argv[3], false, mtmd_helper_init_opt_default());
            require(speaker.bitmap, "Could not read speaker reference");
            auto *gen = mtmd_helper_gen_audio_init(ctx, audio);
            require(gen, "Could not initialize speech generation");
            emit(@{@"event": @"ready"});
            std::string line;
            while (std::getline(std::cin, line)) {
                @autoreleasepool {
                    NSData *data = [NSData dataWithBytes:line.data() length:line.size()];
                    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    require([request isKindOfClass:NSDictionary.class], "Invalid narration request");
                    for (NSString *key in @[@"id", @"text", @"language", @"path"]) {
                        require([request[key] isKindOfClass:NSString.class], "Missing narration field");
                    }
                    // The helper resets its audio state, but the backbone KV cache is ours to clear.
                    llama_memory_clear(llama_get_memory(ctx), true);
                    uint32_t seed = [request[@"seed"] isKindOfClass:NSNumber.class] ? [request[@"seed"] unsignedIntValue] : 7;
                    auto *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
                    if (!biases.empty()) {
                        llama_sampler_chain_add(sampler, llama_sampler_init_logit_bias(
                            llama_vocab_n_tokens(vocab), (int32_t) biases.size(), biases.data()));
                    }
                    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(50));
                    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(1.0f, 1));
                    llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05f, 1));
                    llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7f));
                    llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed));
                    mtmd_helper_gen_audio_inp input{};
                    input.prompt = [request[@"text"] UTF8String];
                    input.prompt_len = strlen(input.prompt);
                    input.speaker_ref = speaker.bitmap;
                    input.lang = [request[@"language"] UTF8String];
                    input.top_k = 50;
                    input.top_p = 1;
                    input.seed = seed;
                    const bool streaming = [request[@"stream"] boolValue];
                    input.out_type = streaming ? MTMD_HELPER_GEN_AUDIO_OUTTYPE_PCM : MTMD_HELPER_GEN_AUDIO_OUTTYPE_WAV;
                    require(mtmd_helper_gen_audio_set_input(gen, &input) == 0, "Speech input failed");
                    int remaining;
                    do {
                        remaining = mtmd_helper_gen_audio_step_prompt(gen, 512);
                        require(remaining >= 0, "Speech prompt failed");
                    } while (remaining > 0);
                    int64_t emittedSamples = 0;
                    int chunkIndex = 0;
                    bool speechStarted = false;
                    auto publish = [&](bool final = false) {
                        int32_t rate; const char *bytes; size_t length; int64_t samples;
                        require(mtmd_helper_gen_audio_get_output(gen, &rate, &bytes, &length, &samples) == 0,
                                "Could not decode streaming audio");
                        require(rate > 0 && samples >= emittedSamples && length == (size_t)samples * sizeof(float),
                                "Invalid streaming PCM");
                        const float *pcm = reinterpret_cast<const float *>(bytes);
                        int64_t begin = emittedSamples;
                        // Trim only initial silence. Never trim the joins between streamed blocks.
                        if (!speechStarted) {
                            const int window = std::max(1, rate / 100);
                            int64_t onset = -1;
                            for (int64_t i = 0; i < samples; i += window) {
                                double energy = 0;
                                const int64_t end = std::min(samples, i + window);
                                for (int64_t j = i; j < end; ++j) energy += pcm[j] * pcm[j];
                                if (energy / (end - i) > 0.0000032) { onset = i; break; }
                            }
                            if (onset < 0) return;
                            begin = std::max<int64_t>(0, onset - rate * 0.04);
                            if (!final && samples - begin < rate * 0.6) return;
                            speechStarted = true;
                        }
                        if (samples == begin) return;
                        NSString *path = [request[@"path"] stringByAppendingFormat:@".part-%d.pcm", chunkIndex];
                        NSData *data = [NSData dataWithBytes:pcm + begin length:(samples - begin) * sizeof(float)];
                        require([data writeToFile:path options:NSDataWritingAtomic error:nil], "Could not write streaming audio");
                        emit(@{@"event": @"partial", @"id": request[@"id"], @"path": path,
                               @"chunk": @(chunkIndex++), @"samples": @(samples - begin), @"sampleRate": @(rate)});
                        emittedSamples = samples;
                    };
                    bool stop = false;
                    int frames = 0;
                    const float *hidden = llama_get_embeddings_ith(ctx, -1);
                    while (!stop && frames < 1024) {
                        llama_token token = llama_sampler_sample(sampler, ctx, -1);
                        const float *next = nullptr;
                        require(mtmd_helper_gen_audio_step_gen(gen, token, hidden, &next, &stop) == 0, "Speech generation failed");
                        if (!next) break;
                        hidden = next;
                        ++frames;
                        // Only complete decoder windows may advance state before end-of-speech.
                        if (streaming && narrationCanPublish(frames)) publish();
                    }
                    llama_sampler_free(sampler);
                    require(frames < 1024, "Speech exceeded the generation limit");
                    if (streaming) {
                        publish(true);
                        require(speechStarted, "The speech model returned silence");
                    } else {
                        int32_t rate; const char *bytes; size_t length; int64_t samples;
                        require(mtmd_helper_gen_audio_get_output(gen, &rate, &bytes, &length, &samples) == 0 && samples > 0,
                                "Speech produced no audio");
                        NSData *wav = [NSData dataWithBytes:bytes length:length];
                        require([wav writeToFile:request[@"path"] options:NSDataWritingAtomic error:nil], "Could not write narration audio");
                    }
                    emit(@{@"event": @"audio", @"id": request[@"id"], @"path": request[@"path"]});
                }
            }
            mtmd_helper_gen_audio_free(gen);
            mtmd_bitmap_free(speaker.bitmap);
            mtmd_free(audio);
            llama_free(ctx);
            llama_model_free(model);
            llama_backend_free();
        } catch (const std::exception &error) {
            emit(@{@"event": @"error", @"error": [NSString stringWithUTF8String:error.what()]});
            return 1;
        }
    }
    return 0;
}
