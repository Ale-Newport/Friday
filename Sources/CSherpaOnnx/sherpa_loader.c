#include "CSherpaOnnx.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define CSHERPA_RESOLVE(member, symbol)                                                     \
    do {                                                                                    \
        api->member = (__typeof__(api->member))dlsym(handle, symbol);                       \
        if (api->member == NULL) {                                                          \
            snprintf(error, error_capacity, "the library does not export `%s`", symbol);    \
            dlclose(handle);                                                                \
            memset(api, 0, sizeof(*api));                                                   \
            return CSHERPA_LOAD_MISSING_SYMBOL;                                             \
        }                                                                                   \
    } while (0)

csherpa_load_status_t csherpa_load(const char *path, csherpa_api_t *api, char *error, size_t error_capacity) {
    if (api == NULL || error == NULL || error_capacity == 0) {
        return CSHERPA_LOAD_NOT_FOUND;
    }
    memset(api, 0, sizeof(*api));
    error[0] = '\0';

    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        const char *reason = dlerror();
        snprintf(error, error_capacity, "%s", reason != NULL ? reason : "dlopen failed");
        return CSHERPA_LOAD_NOT_FOUND;
    }

    CSHERPA_RESOLVE(get_version_str, "SherpaOnnxGetVersionStr");
    CSHERPA_RESOLVE(create_keyword_spotter, "SherpaOnnxCreateKeywordSpotter");
    CSHERPA_RESOLVE(destroy_keyword_spotter, "SherpaOnnxDestroyKeywordSpotter");
    CSHERPA_RESOLVE(create_keyword_stream, "SherpaOnnxCreateKeywordStream");
    CSHERPA_RESOLVE(create_keyword_stream_with_keywords, "SherpaOnnxCreateKeywordStreamWithKeywords");
    CSHERPA_RESOLVE(destroy_online_stream, "SherpaOnnxDestroyOnlineStream");
    CSHERPA_RESOLVE(accept_waveform, "SherpaOnnxOnlineStreamAcceptWaveform");
    CSHERPA_RESOLVE(input_finished, "SherpaOnnxOnlineStreamInputFinished");
    CSHERPA_RESOLVE(is_ready, "SherpaOnnxIsKeywordStreamReady");
    CSHERPA_RESOLVE(decode, "SherpaOnnxDecodeKeywordStream");
    CSHERPA_RESOLVE(reset, "SherpaOnnxResetKeywordStream");
    CSHERPA_RESOLVE(get_result, "SherpaOnnxGetKeywordResult");
    CSHERPA_RESOLVE(destroy_result, "SherpaOnnxDestroyKeywordResult");
    CSHERPA_RESOLVE(create_recognizer, "SherpaOnnxCreateOnlineRecognizer");
    CSHERPA_RESOLVE(destroy_recognizer, "SherpaOnnxDestroyOnlineRecognizer");
    CSHERPA_RESOLVE(create_recognizer_stream, "SherpaOnnxCreateOnlineStream");
    CSHERPA_RESOLVE(recognizer_is_ready, "SherpaOnnxIsOnlineStreamReady");
    CSHERPA_RESOLVE(recognizer_decode, "SherpaOnnxDecodeOnlineStream");
    CSHERPA_RESOLVE(recognizer_get_result, "SherpaOnnxGetOnlineStreamResult");
    CSHERPA_RESOLVE(recognizer_destroy_result, "SherpaOnnxDestroyOnlineRecognizerResult");

    api->library = handle;
    return CSHERPA_LOAD_OK;
}

csherpa_load_status_t csherpa_load_speech(const char *path, csherpa_speech_api_t *api, char *error, size_t error_capacity) {
    if (api == NULL || error == NULL || error_capacity == 0) {
        return CSHERPA_LOAD_NOT_FOUND;
    }
    memset(api, 0, sizeof(*api));
    error[0] = '\0';

    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        const char *reason = dlerror();
        snprintf(error, error_capacity, "%s", reason != NULL ? reason : "dlopen failed");
        return CSHERPA_LOAD_NOT_FOUND;
    }

    CSHERPA_RESOLVE(get_version_str, "SherpaOnnxGetVersionStr");
    CSHERPA_RESOLVE(create_tts, "SherpaOnnxCreateOfflineTts");
    CSHERPA_RESOLVE(destroy_tts, "SherpaOnnxDestroyOfflineTts");
    CSHERPA_RESOLVE(tts_sample_rate, "SherpaOnnxOfflineTtsSampleRate");
    CSHERPA_RESOLVE(tts_num_speakers, "SherpaOnnxOfflineTtsNumSpeakers");
    CSHERPA_RESOLVE(tts_generate, "SherpaOnnxOfflineTtsGenerateWithConfig");
    CSHERPA_RESOLVE(tts_destroy_audio, "SherpaOnnxDestroyOfflineTtsGeneratedAudio");
    CSHERPA_RESOLVE(create_vad, "SherpaOnnxCreateVoiceActivityDetector");
    CSHERPA_RESOLVE(destroy_vad, "SherpaOnnxDestroyVoiceActivityDetector");
    CSHERPA_RESOLVE(vad_accept_waveform, "SherpaOnnxVoiceActivityDetectorAcceptWaveform");
    CSHERPA_RESOLVE(vad_empty, "SherpaOnnxVoiceActivityDetectorEmpty");
    CSHERPA_RESOLVE(vad_detected, "SherpaOnnxVoiceActivityDetectorDetected");
    CSHERPA_RESOLVE(vad_front, "SherpaOnnxVoiceActivityDetectorFront");
    CSHERPA_RESOLVE(vad_pop, "SherpaOnnxVoiceActivityDetectorPop");
    CSHERPA_RESOLVE(vad_clear, "SherpaOnnxVoiceActivityDetectorClear");
    CSHERPA_RESOLVE(vad_flush, "SherpaOnnxVoiceActivityDetectorFlush");
    CSHERPA_RESOLVE(vad_reset, "SherpaOnnxVoiceActivityDetectorReset");
    CSHERPA_RESOLVE(vad_destroy_segment, "SherpaOnnxDestroySpeechSegment");

    api->library = handle;
    return CSHERPA_LOAD_OK;
}
