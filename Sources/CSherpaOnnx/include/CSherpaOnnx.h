// CSherpaOnnx — a minimal runtime loader for the sherpa-onnx C library (keyword spotting, plus the streaming recogniser that
// the voice-tuning tool uses to ask the same network which sounds it hears).
//
// Same idea as CPorcupine, and for the same reasons:
//   * The app (and `swift test`) builds and launches even when libsherpa-onnx-c-api.dylib is absent; a missing
//     library becomes an ordinary, recoverable engine error rather than a dyld crash at launch.
//   * The function table is typed from the *vendored official header* with `__typeof__`, so a signature change in a
//     newer release is a compile error here, not a silent ABI mismatch. (The header is pinned to the same release as
//     the library: see Vendor/SherpaOnnx/sherpa.lock.)
//
// This is the only translation unit in the project that knows sherpa-onnx's C API.

#ifndef CSHERPAONNX_H
#define CSHERPAONNX_H

#include <stddef.h>
#include "sherpa-onnx-c-api.h"  // vendored, unmodified: sherpa-onnx/c-api/c-api.h at the pinned release

#ifdef __cplusplus
extern "C" {
#endif

/// Function table resolved from libsherpa-onnx-c-api.dylib. Every member is non-NULL after a successful
/// `csherpa_load`.
typedef struct {
    void *library;  // dlopen handle (kept for the process lifetime; never dlclose'd)

    __typeof__(SherpaOnnxGetVersionStr)                         *get_version_str;
    __typeof__(SherpaOnnxCreateKeywordSpotter)                  *create_keyword_spotter;
    __typeof__(SherpaOnnxDestroyKeywordSpotter)                 *destroy_keyword_spotter;
    __typeof__(SherpaOnnxCreateKeywordStream)                   *create_keyword_stream;
    __typeof__(SherpaOnnxCreateKeywordStreamWithKeywords)       *create_keyword_stream_with_keywords;
    __typeof__(SherpaOnnxDestroyOnlineStream)                   *destroy_online_stream;
    __typeof__(SherpaOnnxOnlineStreamAcceptWaveform)            *accept_waveform;
    __typeof__(SherpaOnnxOnlineStreamInputFinished)             *input_finished;
    __typeof__(SherpaOnnxIsKeywordStreamReady)                  *is_ready;
    __typeof__(SherpaOnnxDecodeKeywordStream)                   *decode;
    __typeof__(SherpaOnnxResetKeywordStream)                    *reset;
    __typeof__(SherpaOnnxGetKeywordResult)                      *get_result;
    __typeof__(SherpaOnnxDestroyKeywordResult)                  *destroy_result;
    // The streaming recogniser (same network, no keyword): what does the model hear?
    __typeof__(SherpaOnnxCreateOnlineRecognizer)                *create_recognizer;
    __typeof__(SherpaOnnxDestroyOnlineRecognizer)               *destroy_recognizer;
    __typeof__(SherpaOnnxCreateOnlineStream)                    *create_recognizer_stream;
    __typeof__(SherpaOnnxIsOnlineStreamReady)                   *recognizer_is_ready;
    __typeof__(SherpaOnnxDecodeOnlineStream)                    *recognizer_decode;
    __typeof__(SherpaOnnxGetOnlineStreamResult)                 *recognizer_get_result;
    __typeof__(SherpaOnnxDestroyOnlineRecognizerResult)         *recognizer_destroy_result;
} csherpa_api_t;

typedef enum {
    CSHERPA_LOAD_OK = 0,
    CSHERPA_LOAD_NOT_FOUND = 1,       // dlopen failed (missing file, wrong architecture, bad signature, missing dependency …)
    CSHERPA_LOAD_MISSING_SYMBOL = 2,  // library loaded but an expected export is absent
} csherpa_load_status_t;

/// Loads the library at `path` (an absolute path) and resolves all symbols into `api`. Its dependency
/// (libonnxruntime.dylib) is found next to it. On failure `api` is zeroed and a human-readable reason is written to
/// `error`.
csherpa_load_status_t csherpa_load(const char *path, csherpa_api_t *api, char *error, size_t error_capacity);

/// The speech side of the same library: offline text-to-speech (Kokoro) and voice-activity detection (Silero). A
/// second table so the wake-word engine's loader above stays exactly as it was; both may be loaded from the same
/// file (dlopen hands back the same handle). Every member is non-NULL after a successful `csherpa_load_speech`.
///
/// Note: the "no-tts" build of the library exports the TTS entry points too, as stubs that return NULL. A NULL from
/// `create_tts` therefore means either a bad configuration or a library built without text-to-speech.
typedef struct {
    void *library;  // dlopen handle (kept for the process lifetime; never dlclose'd)

    __typeof__(SherpaOnnxGetVersionStr)                         *get_version_str;
    // Offline text to speech. Only the non-deprecated generate entry point: it streams chunks through a callback
    // that may return 0 to stop generation early.
    __typeof__(SherpaOnnxCreateOfflineTts)                      *create_tts;
    __typeof__(SherpaOnnxDestroyOfflineTts)                     *destroy_tts;
    __typeof__(SherpaOnnxOfflineTtsSampleRate)                  *tts_sample_rate;
    __typeof__(SherpaOnnxOfflineTtsNumSpeakers)                 *tts_num_speakers;
    __typeof__(SherpaOnnxOfflineTtsGenerateWithConfig)          *tts_generate;
    __typeof__(SherpaOnnxDestroyOfflineTtsGeneratedAudio)       *tts_destroy_audio;
    // Voice activity detection.
    __typeof__(SherpaOnnxCreateVoiceActivityDetector)           *create_vad;
    __typeof__(SherpaOnnxDestroyVoiceActivityDetector)          *destroy_vad;
    __typeof__(SherpaOnnxVoiceActivityDetectorAcceptWaveform)   *vad_accept_waveform;
    __typeof__(SherpaOnnxVoiceActivityDetectorEmpty)            *vad_empty;
    __typeof__(SherpaOnnxVoiceActivityDetectorDetected)         *vad_detected;
    __typeof__(SherpaOnnxVoiceActivityDetectorFront)            *vad_front;
    __typeof__(SherpaOnnxVoiceActivityDetectorPop)              *vad_pop;
    __typeof__(SherpaOnnxVoiceActivityDetectorClear)            *vad_clear;
    __typeof__(SherpaOnnxVoiceActivityDetectorFlush)            *vad_flush;
    __typeof__(SherpaOnnxVoiceActivityDetectorReset)            *vad_reset;
    __typeof__(SherpaOnnxDestroySpeechSegment)                  *vad_destroy_segment;
} csherpa_speech_api_t;

/// Same contract as `csherpa_load`, for the speech table.
csherpa_load_status_t csherpa_load_speech(const char *path, csherpa_speech_api_t *api, char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif  // CSHERPAONNX_H
