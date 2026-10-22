#ifndef AIRPLAY_BRIDGE_H
#define AIRPLAY_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*ap_video_frame_cb)(
    void *ctx,
    const uint8_t *data,
    int data_len,
    bool is_h265,
    uint64_t ntp_time_local,
    float latency_ms
);

typedef void (*ap_video_size_cb)(
    void *ctx,
    float width_source,
    float height_source,
    float width,
    float height
);

typedef void (*ap_client_state_cb)(
    void *ctx,
    bool connected,
    const char *client_name,
    const char *client_model
);

typedef void (*ap_log_cb)(
    void *ctx,
    int level,
    const char *message
);

int airplay_bridge_start(
    const char *server_name,
    int max_width,
    int max_height,
    int max_fps,
    bool enable_p2p,
    void *ctx,
    ap_video_frame_cb on_video_frame,
    ap_video_size_cb on_video_size,
    ap_client_state_cb on_client_state,
    ap_log_cb on_log
);

void airplay_bridge_stop(void);
void airplay_bridge_disconnect_client(void);
bool airplay_bridge_is_running(void);
int airplay_bridge_get_port(void);

#ifdef __cplusplus
}
#endif

#endif /* AIRPLAY_BRIDGE_H */
