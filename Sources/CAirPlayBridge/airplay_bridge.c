#include "include/airplay_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/select.h>
#include <sys/utsname.h>

#include "raop.h"
#include "dnssd.h"
#include "stream.h"
#include "logger.h"

static dnssd_t *g_dnssd = NULL;
static raop_t *g_raop = NULL;
static unsigned short g_port = 0;
static volatile bool g_running = false;
static pthread_t g_service_thread;
static bool g_thread_started = false;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static void *g_ctx = NULL;
static ap_video_frame_cb g_on_video_frame = NULL;
static ap_video_size_cb g_on_video_size = NULL;
static ap_client_state_cb g_on_client_state = NULL;
static ap_log_cb g_on_log = NULL;

static char g_client_name[128] = {0};
static char g_client_model[128] = {0};
static volatile bool g_mirror_active = false;
static int g_open_connections = 0;

/* --- RAOP Callbacks --- */

static void cb_conn_init(void *cls) {
    (void)cls;
    g_open_connections++;
}

static void cb_conn_destroy(void *cls) {
    (void)cls;
    if (g_open_connections > 0) {
        g_open_connections--;
    }
    if (g_open_connections == 0 && g_mirror_active) {
        g_mirror_active = false;
        if (g_on_client_state) {
            g_on_client_state(g_ctx, false, "", "");
        }
    }
}

static void cb_conn_feedback(void *cls) {
    (void)cls;
}

static void cb_conn_reset(void *cls, int reason) {
    (void)cls;
    (void)reason;
    if (g_mirror_active) {
        g_mirror_active = false;
        if (g_on_client_state) {
            g_on_client_state(g_ctx, false, "", "");
        }
    }
}

static void cb_video_reset(void *cls, reset_type_t type) {
    (void)cls;
    (void)type;
    if (g_mirror_active) {
        g_mirror_active = false;
        if (g_on_client_state) {
            g_on_client_state(g_ctx, false, "", "");
        }
    }
}

static int cb_video_set_codec(void *cls, video_codec_t codec) {
    (void)cls;
    (void)codec;
    return 0;
}

static void cb_video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    (void)cls;
    (void)ntp;
    if (!data || !data->data || data->data_len <= 0) {
        return;
    }
    if (!g_mirror_active) {
        g_mirror_active = true;
        if (g_on_client_state) {
            g_on_client_state(
                g_ctx,
                true,
                g_client_name[0] ? g_client_name : "iPad",
                g_client_model[0] ? g_client_model : "iPadOS"
            );
        }
    }
    if (g_on_video_frame) {
        g_on_video_frame(
            g_ctx,
            data->data,
            data->data_len,
            data->is_h265,
            data->ntp_time_local,
            data->latency_ms
        );
    }
}

static void cb_video_report_size(void *cls, float *width_source, float *height_source, float *width, float *height) {
    (void)cls;
    if (g_on_video_size && width_source && height_source && width && height) {
        g_on_video_size(g_ctx, *width_source, *height_source, *width, *height);
    }
}

static void cb_mirror_video_running(void *cls, bool is_running) {
    (void)cls;
    g_mirror_active = is_running;
    if (g_on_client_state) {
        if (is_running) {
            g_on_client_state(
                g_ctx,
                true,
                g_client_name[0] ? g_client_name : "iPad",
                g_client_model[0] ? g_client_model : "iPadOS"
            );
        } else {
            g_on_client_state(g_ctx, false, "", "");
        }
    }
}

static void cb_report_client_request(void *cls, char *deviceid, char *model, char *name, bool *admit) {
    (void)cls;
    (void)deviceid;
    if (admit) {
        *admit = true;
    }
    if (name && name[0]) {
        strncpy(g_client_name, name, sizeof(g_client_name) - 1);
        g_client_name[sizeof(g_client_name) - 1] = '\0';
    }
    if (model && model[0]) {
        strncpy(g_client_model, model, sizeof(g_client_model) - 1);
        g_client_model[sizeof(g_client_model) - 1] = '\0';
    }
}

static void cb_video_pause(void *cls) { (void)cls; }
static void cb_video_resume(void *cls) { (void)cls; }
static void cb_video_flush(void *cls) { (void)cls; }

static void cb_audio_process(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {
    (void)cls; (void)ntp; (void)data;
}
static void cb_audio_flush(void *cls) { (void)cls; }
static double cb_audio_set_client_volume(void *cls) { (void)cls; return 0.0; }
static void cb_audio_set_volume(void *cls, float volume) { (void)cls; (void)volume; }
static void cb_audio_get_format(void *cls, unsigned char *ct, unsigned short *spf, bool *usingScreen, bool *isMedia, uint64_t *audioFormat) {
    (void)cls; (void)ct; (void)spf; (void)usingScreen; (void)isMedia; (void)audioFormat;
}
static void cb_audio_set_metadata(void *cls, const void *buffer, int buflen) {
    (void)cls; (void)buffer; (void)buflen;
}
static void cb_audio_set_coverart(void *cls, const void *buffer, int buflen) {
    (void)cls; (void)buffer; (void)buflen;
}
static void cb_audio_stop_coverart_rendering(void *cls) { (void)cls; }
static void cb_audio_set_progress(void *cls, uint32_t *start, uint32_t *curr, uint32_t *end) {
    (void)cls; (void)start; (void)curr; (void)end;
}
static void cb_display_pin(void *cls, char *pin) { (void)cls; (void)pin; }
static void cb_register_client(void *cls, const char *device_id, const char *pk_str, const char *name) {
    (void)cls; (void)device_id; (void)pk_str; (void)name;
}
static bool cb_check_register(void *cls, const char *pk_str) { (void)cls; (void)pk_str; return true; }
static const char *cb_passwd(void *cls, int *len) {
    (void)cls;
    if (len) *len = 0;
    return NULL;
}
static void cb_export_dacp(void *cls, const char *active_remote, const char *dacp_id) {
    (void)cls; (void)active_remote; (void)dacp_id;
}

static void cb_on_video_play(void *cls, const char *location, const float start_position) {
    (void)cls; (void)location; (void)start_position;
}
static void cb_on_video_scrub(void *cls, const float position) { (void)cls; (void)position; }
static void cb_on_video_rate(void *cls, const float rate) { (void)cls; (void)rate; }
static void cb_on_video_stop(void *cls) { (void)cls; }
static float cb_on_video_playlist_remove(void *cls) { (void)cls; return 0.0f; }
static void cb_on_video_acquire_playback_info(void *cls, playback_info_t *playback_video) {
    (void)cls;
    if (playback_video) {
        playback_video->position = -1.0;
        playback_video->duration = -1.0;
    }
}

static void cb_log(void *cls, int level, const char *msg) {
    (void)cls;
    if (g_on_log && msg) {
        g_on_log(g_ctx, level, msg);
    }
}

/* --- Background thread to service Bonjour sockets --- */
static void *dnssd_service_loop(void *arg) {
    (void)arg;
    while (g_running && g_dnssd) {
        int fd_raop = dnssd_get_service_fd(g_dnssd, DNSSD_SERVICE_RAOP);
        int fd_airplay = dnssd_get_service_fd(g_dnssd, DNSSD_SERVICE_AIRPLAY);
        if (fd_raop < 0 && fd_airplay < 0) {
            usleep(100000);
            continue;
        }
        fd_set rfds;
        FD_ZERO(&rfds);
        int maxfd = -1;
        if (fd_raop >= 0) {
            FD_SET(fd_raop, &rfds);
            if (fd_raop > maxfd) maxfd = fd_raop;
        }
        if (fd_airplay >= 0) {
            FD_SET(fd_airplay, &rfds);
            if (fd_airplay > maxfd) maxfd = fd_airplay;
        }
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 100000; /* 100ms */
        int ret = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (ret > 0 && g_running && g_dnssd) {
            if (fd_raop >= 0 && FD_ISSET(fd_raop, &rfds)) {
                dnssd_process_service(g_dnssd, DNSSD_SERVICE_RAOP);
            }
            if (fd_airplay >= 0 && FD_ISSET(fd_airplay, &rfds)) {
                dnssd_process_service(g_dnssd, DNSSD_SERVICE_AIRPLAY);
            }
        }
    }
    return NULL;
}

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
) {
    pthread_mutex_lock(&g_lock);
    if (g_running) {
        pthread_mutex_unlock(&g_lock);
        airplay_bridge_stop();
        pthread_mutex_lock(&g_lock);
    }

    g_ctx = ctx;
    g_on_video_frame = on_video_frame;
    g_on_video_size = on_video_size;
    g_on_client_state = on_client_state;
    g_on_log = on_log;
    g_mirror_active = false;
    g_open_connections = 0;
    memset(g_client_name, 0, sizeof(g_client_name));
    memset(g_client_model, 0, sizeof(g_client_model));

    /* Deterministic locally-administered MAC address distinct from macOS built-in AirPlay Receiver */
    struct utsname ubuf;
    uint8_t host_hash = 0x5A;
    if (uname(&ubuf) == 0) {
        for (size_t i = 0; ubuf.nodename[i] != '\0'; i++) {
            host_hash = (uint8_t)((host_hash * 31) ^ (uint8_t)ubuf.nodename[i]);
        }
    }
    const char hw_addr[6] = {
        (char)0x02, (char)0x49, (char)0x50, (char)0x41, (char)0x44, (char)host_hash
    };
    char mac_str[18];
    snprintf(
        mac_str, sizeof(mac_str),
        "%02x:%02x:%02x:%02x:%02x:%02x",
        (uint8_t)hw_addr[0], (uint8_t)hw_addr[1], (uint8_t)hw_addr[2],
        (uint8_t)hw_addr[3], (uint8_t)hw_addr[4], (uint8_t)hw_addr[5]
    );

    const char *name = (server_name && server_name[0]) ? server_name : "iPad 畫布視窗";
    int dnssd_error = 0;
    g_dnssd = dnssd_init(name, (int)strlen(name), hw_addr, 6, 0, &dnssd_error);
    if (!g_dnssd || dnssd_error != 0) {
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

#if defined(__APPLE__) && defined(UXPLAY_HAVE_APPLE_P2P)
    dnssd_set_peer_to_peer(g_dnssd, enable_p2p ? 1 : 0);
#else
    (void)enable_p2p;
#endif

    dnssd_set_airplay_features(g_dnssd,  0, 0);
    dnssd_set_airplay_features(g_dnssd,  1, 1);
    dnssd_set_airplay_features(g_dnssd,  2, 1);
    dnssd_set_airplay_features(g_dnssd,  3, 0);
    dnssd_set_airplay_features(g_dnssd,  4, 0);
    dnssd_set_airplay_features(g_dnssd,  5, 1);
    dnssd_set_airplay_features(g_dnssd,  6, 1);
    dnssd_set_airplay_features(g_dnssd,  7, 1); /* Screen Mirroring */
    dnssd_set_airplay_features(g_dnssd,  8, 0);
    dnssd_set_airplay_features(g_dnssd,  9, 1);
    dnssd_set_airplay_features(g_dnssd, 10, 1);
    dnssd_set_airplay_features(g_dnssd, 11, 1);
    dnssd_set_airplay_features(g_dnssd, 12, 1);
    dnssd_set_airplay_features(g_dnssd, 13, 1);
    dnssd_set_airplay_features(g_dnssd, 14, 1);
    dnssd_set_airplay_features(g_dnssd, 15, 1);
    dnssd_set_airplay_features(g_dnssd, 16, 1);
    dnssd_set_airplay_features(g_dnssd, 17, 1);
    dnssd_set_airplay_features(g_dnssd, 18, 1);
    dnssd_set_airplay_features(g_dnssd, 19, 1);
    dnssd_set_airplay_features(g_dnssd, 20, 1);
    dnssd_set_airplay_features(g_dnssd, 21, 1);
    dnssd_set_airplay_features(g_dnssd, 22, 1);
    dnssd_set_airplay_features(g_dnssd, 23, 0);
    dnssd_set_airplay_features(g_dnssd, 24, 0);
    dnssd_set_airplay_features(g_dnssd, 25, 1);
    dnssd_set_airplay_features(g_dnssd, 26, 0);
    dnssd_set_airplay_features(g_dnssd, 27, 0);
    dnssd_set_airplay_features(g_dnssd, 28, 1);
    dnssd_set_airplay_features(g_dnssd, 29, 0);
    dnssd_set_airplay_features(g_dnssd, 30, 1);
    dnssd_set_airplay_features(g_dnssd, 31, 0);
    dnssd_set_airplay_features(g_dnssd, 42, 0); /* H.264 hardware decoding */

    raop_callbacks_t cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.cls = ctx;
    cbs.conn_init = cb_conn_init;
    cbs.conn_destroy = cb_conn_destroy;
    cbs.conn_feedback = cb_conn_feedback;
    cbs.conn_reset = cb_conn_reset;
    cbs.video_reset = cb_video_reset;
    cbs.video_set_codec = cb_video_set_codec;
    cbs.video_process = cb_video_process;
    cbs.video_report_size = cb_video_report_size;
    cbs.mirror_video_running = cb_mirror_video_running;
    cbs.report_client_request = cb_report_client_request;
    cbs.video_pause = cb_video_pause;
    cbs.video_resume = cb_video_resume;
    cbs.video_flush = cb_video_flush;
    cbs.audio_process = cb_audio_process;
    cbs.audio_flush = cb_audio_flush;
    cbs.audio_set_client_volume = cb_audio_set_client_volume;
    cbs.audio_set_volume = cb_audio_set_volume;
    cbs.audio_get_format = cb_audio_get_format;
    cbs.audio_set_metadata = cb_audio_set_metadata;
    cbs.audio_set_coverart = cb_audio_set_coverart;
    cbs.audio_stop_coverart_rendering = cb_audio_stop_coverart_rendering;
    cbs.audio_set_progress = cb_audio_set_progress;
    cbs.display_pin = cb_display_pin;
    cbs.register_client = cb_register_client;
    cbs.check_register = cb_check_register;
    cbs.passwd = cb_passwd;
    cbs.export_dacp = cb_export_dacp;
    cbs.on_video_play = cb_on_video_play;
    cbs.on_video_scrub = cb_on_video_scrub;
    cbs.on_video_rate = cb_on_video_rate;
    cbs.on_video_stop = cb_on_video_stop;
    cbs.on_video_playlist_remove = cb_on_video_playlist_remove;
    cbs.on_video_acquire_playback_info = cb_on_video_acquire_playback_info;

    g_raop = raop_init(&cbs);
    if (!g_raop) {
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
        pthread_mutex_unlock(&g_lock);
        return -2;
    }

    raop_set_log_callback(g_raop, cb_log, ctx);
    raop_set_log_level(g_raop, LOGGER_INFO);

    if (raop_init2(g_raop, 1, mac_str, "") != 0) {
        raop_destroy(g_raop);
        g_raop = NULL;
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
        pthread_mutex_unlock(&g_lock);
        return -3;
    }

    raop_set_plist(g_raop, "width", max_width > 0 ? max_width : 2560);
    raop_set_plist(g_raop, "height", max_height > 0 ? max_height : 1920);
    raop_set_plist(g_raop, "refreshRate", 60);
    raop_set_plist(g_raop, "maxFPS", max_fps > 0 ? max_fps : 60);
    raop_set_plist(g_raop, "overscanned", 0);

    unsigned short tcp[2] = {0, 0};
    unsigned short udp[3] = {0, 0, 0};
    raop_set_tcp_ports(g_raop, tcp);
    raop_set_udp_ports(g_raop, udp);

    g_port = 0;
    if (raop_start_httpd(g_raop, &g_port) < 0 || g_port == 0) {
        raop_destroy(g_raop);
        g_raop = NULL;
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
        pthread_mutex_unlock(&g_lock);
        return -4;
    }
    raop_set_port(g_raop, g_port);
    raop_set_dnssd(g_raop, g_dnssd);

    if (dnssd_register_raop(g_dnssd, g_port) != 0) {
        raop_destroy(g_raop);
        g_raop = NULL;
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
        pthread_mutex_unlock(&g_lock);
        return -5;
    }

    if (dnssd_register_airplay(g_dnssd, g_port) != 0) {
        dnssd_unregister_raop(g_dnssd);
        raop_destroy(g_raop);
        g_raop = NULL;
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
        pthread_mutex_unlock(&g_lock);
        return -6;
    }

    g_running = true;
    if (pthread_create(&g_service_thread, NULL, dnssd_service_loop, NULL) == 0) {
        g_thread_started = true;
    }

    pthread_mutex_unlock(&g_lock);
    return 0;
}

void airplay_bridge_disconnect_client(void) {
    pthread_mutex_lock(&g_lock);
    if (g_raop) {
        raop_remove_known_connections(g_raop);
    }
    if (g_mirror_active) {
        g_mirror_active = false;
        if (g_on_client_state) {
            g_on_client_state(g_ctx, false, "", "");
        }
    }
    pthread_mutex_unlock(&g_lock);
}

void airplay_bridge_stop(void) {
    pthread_mutex_lock(&g_lock);
    if (!g_running && !g_raop && !g_dnssd) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_running = false;
    pthread_mutex_unlock(&g_lock);

    if (g_thread_started) {
        pthread_join(g_service_thread, NULL);
        g_thread_started = false;
    }

    pthread_mutex_lock(&g_lock);
    if (g_dnssd) {
        dnssd_unregister_raop(g_dnssd);
        dnssd_unregister_airplay(g_dnssd);
    }
    if (g_raop) {
        raop_destroy(g_raop);
        g_raop = NULL;
    }
    if (g_dnssd) {
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
    }
    g_port = 0;
    g_mirror_active = false;
    pthread_mutex_unlock(&g_lock);
}

bool airplay_bridge_is_running(void) {
    return g_running;
}

int airplay_bridge_get_port(void) {
    return (int)g_port;
}
