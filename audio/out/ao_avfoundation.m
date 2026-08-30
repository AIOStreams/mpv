/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "ao.h"
#include "audio/format.h"
#include "audio/out/ao_coreaudio_chmap.h"
#include "audio/out/ao_coreaudio_utils.h"
#include "common/common.h"
#include "common/msg.h"
#include "internal.h"
#include "options/m_option.h"
#include "osdep/timer.h"
#include "ta/ta_talloc.h"

#include <stdatomic.h>
#include <errno.h>

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreAudioTypes/CoreAudioTypes.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMedia/CoreMedia.h>


@interface AVObserver : NSObject {
    struct ao *ao;
}
- (void)handleRestartNotification:(NSNotification*)notification;
@end

@interface AVPLoader : NSObject <AVAssetResourceLoaderDelegate> {
    struct ao *ao;
@public
    NSMutableArray<AVAssetResourceLoadingRequest *> *requests;
}
- (instancetype)initWithAO:(struct ao*)_ao;
- (void)invalidate;
@end

struct priv {
    // PCM sink
    AVSampleBufferAudioRenderer *renderer;
    AVSampleBufferRenderSynchronizer *synchronizer;
    dispatch_queue_t queue;
    CMAudioFormatDescriptionRef format_description;
    AVObserver *observer;
    int64_t end_time_av;

    // Compressed AC3/EAC3 sink. The raw elementary stream is served to an
    // AVPlayer through an AVAssetResourceLoader; the system's own Dolby
    // pipeline decodes it and, on Atmos-capable routes, renders the JOC
    // object audio (Dolby MAT over HDMI on tvOS). This is the only
    // Atmos-capable output path on tvOS: feeding compressed sample buffers
    // to AVSampleBufferAudioRenderer decodes only the channel bed.
    bool spdif;
    int spdif_rate;              // audio rate of the elementary stream
    int spdif_burst_size;        // IEC 61937 burst repetition period, bytes
    int spdif_data_type;         // IEC 61937 Pc data type for this format
    const char *spdif_uti;       // UTI declared to AVPlayer
    const char *spdif_ext;       // fake stream file extension
    bool spdif_reload_requested;
    uint8_t *stash;              // carries partial IEC bursts between pulls
    int stash_len;
    int stash_size;

    AVPlayer *player;
    AVPlayerItem *item;
    AVURLAsset *asset;
    AVPLoader *loader;
    // Periodic driver for the compressed sink: pulls from mpv, serves the
    // loader, and applies transport state. Created once, idle at
    // DISPATCH_TIME_FOREVER when not streaming; releasing a suspended
    // source traps, so it stays resumed for its whole life.
    dispatch_source_t avp_timer;
    // Elementary-stream window served to AVPlayer, indexed by stream byte
    // offset. Bytes behind the loader's read position are retained
    // (bounded) so a player-initiated restart from offset 0 can be served.
    uint8_t *es_buf;
    int es_size;
    int es_len;
    int64_t es_head;             // stream offset of es_buf[0]
    int64_t es_pts;              // ns of audio appended since the item epoch
    int64_t pulled_samples;      // IEC samples handed over by ao_read_data
    int64_t es_dropped_ns;       // AU periods pulled but never appended
    // Last complete access unit, kept to satisfy far-offset probes: the
    // system estimates duration/bitrate by reading near the end of the fake
    // endless resource, and refusing those reads parks preroll forever.
    // Probe offsets are never reached by playback, which starts at zero, so
    // any valid access units satisfy them.
    uint8_t *au_buf;
    int au_len;
    bool avp_playing;            // desired transport state
    bool avp_rate_applied;       // rate 1 has been handed to AVPlayer
    bool avp_start_seeked;       // seek-to-start workaround already tried
    bool avp_eof;
    int64_t avp_start_deadline;  // mp_time_ns() deadline; -1 = healthy
    int64_t avp_primed_pts;      // es_pts at the last observed priming progress
    int avp_last_item_status;    // last logged AVPlayerItemStatus
    int avp_last_tcs;            // last logged AVPlayerTimeControlStatus
    int avp_heartbeat;           // verbose position log divider
    int64_t avp_lead_ns;         // steady-state ES feed lead (from option)
    // Whether this AO accepts compressed AC3/EAC3 and routes it through
    // AVPlayer. Disable to let the next configured audio output handle the
    // bitstream instead.
    bool opt_accept_compressed;
    // How far ahead of the observed playhead the elementary stream is fed,
    // in seconds. The system's audio decode pipeline reads unboundedly far
    // ahead of the playhead (the loader's read offset sits pinned at the
    // write head at any lead), and it consumes its buffered stream in fixed
    // ~1.8 s quanta. When only 2 s were fed the refill periodically overran
    // the write head and the renderer skipped ~100-220 ms of audio to stay
    // on clock -- an audible dropout every 1.79 s during (E-)AC-3
    // passthrough on tvOS (plezy#1300, plezy#1776), independent of stream
    // bitrate and route. 8 s gives the pipeline 4x its own quantum; measured
    // dropouts over ~4 min fell from 21/min (Plezy 2.15) and 10.6/min
    // (this AO at 2 s) to zero.
    double opt_compressed_lead;
#if TARGET_OS_OSX
    // The bounded PCM lookahead is macOS-only. That is where --volume is
    // driven from a slider or the keyboard and the lag is felt; on tvOS and
    // iOS the hardware volume never reaches mpv's software gain, and the
    // renderer's deep queue is what carries AirPlay. Everything below
    // compiles out entirely there.
    //
    // How far ahead of the playhead the PCM path is allowed to enqueue.
    // AVSampleBufferAudioRenderer's own backpressure sits far out -- around
    // 1.7s when measured against a local route -- and mpv multiplies the
    // software volume into the samples as it hands them over, so a volume
    // change stays inaudible until that backlog has drained. Bounding the
    // lookahead bounds that delay. 0 leaves the renderer's own depth alone.
    int64_t pcm_lookahead_ns;
    // One-shot, idle at DISPATCH_TIME_FOREVER. Owned here rather than being a
    // dispatch_after so teardown can cancel it: the handler dereferences the
    // AO, which ao_uninit() frees the moment uninit() returns.
    dispatch_source_t feed_timer;
    // Whether the PCM path should be feeding at all. A frozen clock does not
    // drain the queue, so without this the bound stays exceeded and the timer
    // wakes forever re-deciding not to feed. Only mutated on p->queue.
    bool feed_enabled;
    double opt_max_lookahead;
#endif
};

#define IEC61937_HEADER_SIZE 8
#define IEC61937_AC3  0x01
#define IEC61937_EAC3 0x15

// One IEC 61937 burst carries 1536 samples of audio at the base rate.
#define SPDIF_FRAMES_PER_BURST 1536

#define AVP_TICK_NS         MP_TIME_MS_TO_NS(50)
// Startup allowance while the playhead has not moved yet: preroll consumes
// several seconds before the transport engages, and capping it at the
// steady-state lead deadlocks the start against a frozen playhead.
#define AVP_START_LEAD_NS(p) (2 * (p)->avp_lead_ns)
// Minimum priming before the transport is started.
#define AVP_START_MIN_NS    MP_TIME_S_TO_NS(1)
// Deadline for the item to become ready once primed.
#define AVP_READY_GRACE_NS  MP_TIME_S_TO_NS(5)
// Deadline for the playhead to move once the rate is applied.
#define AVP_START_GRACE_NS  MP_TIME_S_TO_NS(2)
// History kept behind the loader's read position for offset-0 restarts.
#define AVP_ES_HISTORY_BYTES (2 * 1024 * 1024)
// Byte budget per second of lead when sizing the ES window: the highest
// legal E-AC-3 rate (6.144 Mb/s) is 768 KiB/s.
#define AVP_ES_LEAD_BYTES_PER_S (768 * 1024)

// A failed compressed AO must reject its immediate reload so mpv can decode
// to PCM. A later successful PCM initialization clears this process-local
// handoff, allowing another track or playback session to try native audio.
static _Atomic bool spdif_format_latch[2];
static char avfoundation_queue_key;

static int spdif_latch_index(int format)
{
    return format == AF_FORMAT_S_EAC3;
}

static void feed_avp(struct ao *ao);

static int64_t CMTimeGetNanoseconds(CMTime time)
{
    time = CMTimeConvertScale(time, 1000000000, kCMTimeRoundingMethod_Default);
    return time.value;
}

static CMTime CMTimeFromNanoseconds(int64_t time)
{
    return CMTimeMake(time, 1000000000);
}

static void avp_timer_idle(struct priv *p)
{
    dispatch_source_set_timer(p->avp_timer, DISPATCH_TIME_FOREVER,
                              DISPATCH_TIME_FOREVER, 0);
}

static void avp_timer_arm(struct priv *p)
{
    dispatch_source_set_timer(
        p->avp_timer,
        dispatch_time(DISPATCH_TIME_NOW, AVP_TICK_NS),
        AVP_TICK_NS, AVP_TICK_NS / 2);
}

// Latch the failing format and force a reinit; init() will then reject the
// format and the player core falls back to PCM decoding.
static void spdif_reload(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->spdif_reload_requested)
        return;
    p->spdif_reload_requested = true;
    atomic_store(&spdif_format_latch[spdif_latch_index(ao->format)], true);
    [p->player setRate:0];
    avp_timer_idle(p);
    ao_request_reload(ao);
}

// Playhead position on the elementary-stream timeline. AVPlayerItem's
// currentTime can update in chunks when a custom resource loader backs
// compressed audio; reading the item's public timebase instead follows its
// audio-device clock correlation continuously, without feeding that chunk
// jitter into mpv's delay estimate. Clamp to the written range: an idle item
// reports 0, and nothing can play past the write head.
static int64_t avp_current_time_ns(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!p->item)
        return 0;
    CMTime t = kCMTimeInvalid;
    CMTimebaseRef timebase = p->item.timebase;
    if (timebase)
        t = CMTimebaseGetTime(timebase);
    if (!CMTIME_IS_NUMERIC(t))
        t = [p->item currentTime];
    if (!CMTIME_IS_NUMERIC(t))
        return 0;
    return MPCLAMP(CMTimeGetNanoseconds(t), 0, p->es_pts);
}

// Most-advanced playhead estimate, used only to pace the feed. The item's
// timebase and its chunk-updated currentTime can disagree by a constant
// offset on some HDMI routes; pacing the 2s feed lead against the laggier
// reading silently thins AVPlayer's real buffer by that offset until
// playback reaches the write head and audibly stalls on a seconds-scale
// cadence. Feeding against the most-advanced reading can only add bounded
// extra lead, which the ES window already absorbs.
static int64_t avp_feed_position_ns(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!p->item)
        return 0;
    int64_t pos = avp_current_time_ns(ao);
    CMTime t = [p->item currentTime];
    if (CMTIME_IS_NUMERIC(t))
        pos = MPMAX(pos, CMTimeGetNanoseconds(t));
    return MPCLAMP(pos, 0, p->es_pts);
}

// Append one burst payload (byte-swapped back to the raw bitstream) to the
// elementary-stream window.
static void avp_append_es(struct ao *ao, const uint8_t *payload, int payload_len)
{
    struct priv *p = ao->priv;

    if (payload_len & 1) {
        // (E-)AC-3 frame sizes are counted in 16-bit words
        MP_WARN(ao, "discarding burst with odd payload length\n");
        p->es_dropped_ns += CMTimeGetNanoseconds(
            CMTimeMake(SPDIF_FRAMES_PER_BURST, p->spdif_rate));
        return;
    }
    if (p->es_len + payload_len > p->es_size) {
        // cannot happen while the lead and history bounds hold
        MP_ERR(ao, "elementary stream window overflow; falling back to PCM\n");
        spdif_reload(ao);
        return;
    }
    uint8_t *dst = p->es_buf + p->es_len;
    // the spdif muxer emits 16-bit LE words; swap back to the raw bitstream
    for (int i = 0; i < payload_len; i += 2) {
        dst[i]     = payload[i + 1];
        dst[i + 1] = payload[i];
    }
    if (dst[0] != 0x0b || dst[1] != 0x77) {
        MP_WARN(ao, "discarding burst without syncframe\n");
        p->es_dropped_ns += CMTimeGetNanoseconds(
            CMTimeMake(SPDIF_FRAMES_PER_BURST, p->spdif_rate));
        return;
    }
    memcpy(p->au_buf, dst, payload_len);
    p->au_len = payload_len;
    p->es_len += payload_len;
    p->es_pts += CMTimeGetNanoseconds(
        CMTimeMake(SPDIF_FRAMES_PER_BURST, p->spdif_rate));
}

// One read/unwrap pass: pull IEC 61937 data from mpv and append every
// complete burst's payload to the elementary stream. Returns false when out
// of data, at EOF, or reloading.
static bool avp_pull(struct ao *ao)
{
    struct priv *p = ao->priv;
    int samplerate = ao->samplerate;
    int sstride = ao->sstride;
    bool eof = false;

    int request_sample_count = samplerate / 10;
    if ((p->stash_size - p->stash_len) / sstride < request_sample_count)
        request_sample_count = (p->stash_size - p->stash_len) / sstride;
    if (request_sample_count <= 0)
        return false;

    int64_t cur_time_av = avp_current_time_ns(ao);
    int64_t cur_time_mp = mp_time_ns();
    int64_t time_delta = CMTimeGetNanoseconds(CMTimeMake(request_sample_count, samplerate));
    // The end time handed to ao_read_data becomes mpv's audio clock verbatim
    // (buffer_state.end_time_ns), and audio-slaved video follows it frame by
    // frame. The IEC 61937 stream is isochronous, so samples pulled measure
    // written stream time exactly (minus AU periods that never reached the
    // ES). es_pts is unusable here: it is credited a whole burst period the
    // moment a payload lands, which sawtooths the clock by up to 32 ms, and
    // video retires every wrap as a visible skip/hold pair (plezy#1776).
    int64_t written_ns = CMTimeGetNanoseconds(
        CMTimeMake(p->pulled_samples, samplerate)) - p->es_dropped_ns;
    void *data[] = {p->stash + p->stash_len};
    int real_sample_count = ao_read_data(ao, data, request_sample_count,
        written_ns - cur_time_av + cur_time_mp + time_delta, &eof, false, true);
    if (eof) {
        p->avp_eof = true;
        ao_stop_streaming(ao);
    }
    if (real_sample_count == 0)
        return false;
    p->stash_len += real_sample_count * sstride;
    p->pulled_samples += real_sample_count;

    // extract every complete IEC 61937 burst
    int pos = 0;
    while (true) {
        while (pos + IEC61937_HEADER_SIZE <= p->stash_len &&
               !(p->stash[pos] == 0x72 && p->stash[pos + 1] == 0xf8 &&
                 p->stash[pos + 2] == 0x1f && p->stash[pos + 3] == 0x4e))
            pos++;
        if (pos + IEC61937_HEADER_SIZE > p->stash_len)
            break;
        int data_type = p->stash[pos + 4] & 0x7f;
        int pd = p->stash[pos + 6] | (p->stash[pos + 7] << 8);
        if (data_type != p->spdif_data_type) {
            MP_WARN(ao, "skipping unexpected IEC 61937 data type 0x%x\n", data_type);
            pos++;
            continue;
        }
        // Pd is the payload length in bits for AC3 and in bytes for EAC3
        int payload_len = data_type == IEC61937_AC3 ? pd / 8 : pd;
        if (payload_len < 8 || payload_len > p->spdif_burst_size - IEC61937_HEADER_SIZE) {
            MP_WARN(ao, "skipping burst with invalid payload length %d\n", payload_len);
            pos++;
            continue;
        }
        if (pos + IEC61937_HEADER_SIZE + MP_ALIGN_UP(payload_len, 2) > p->stash_len)
            break; // incomplete burst; wait for more data
        avp_append_es(ao, p->stash + pos + IEC61937_HEADER_SIZE, payload_len);
        if (p->spdif_reload_requested)
            return false;
        pos += IEC61937_HEADER_SIZE + MP_ALIGN_UP(payload_len, 2);
    }
    if (pos > 0) {
        memmove(p->stash, p->stash + pos, p->stash_len - pos);
        p->stash_len -= pos;
    }
    if (p->stash_len > p->spdif_burst_size * 3) {
        MP_ERR(ao, "no IEC 61937 sync found in %d bytes; falling back to PCM\n",
               p->stash_len);
        p->stash_len = 0;
        spdif_reload(ao);
        return false;
    }
    return !eof;
}

// Serve the pending loading requests from the elementary-stream window and
// trim history the loader has moved past.
static void avp_serve_requests(struct ao *ao)
{
    struct priv *p = ao->priv;
    NSMutableArray<AVAssetResourceLoadingRequest *> *reqs = p->loader->requests;

    for (NSUInteger i = 0; i < reqs.count; ) {
        AVAssetResourceLoadingRequest *req = reqs[i];
        AVAssetResourceLoadingDataRequest *dr = req.dataRequest;
        int64_t off = dr.currentOffset;
        if (off < p->es_head) {
            // trimmed past; the item will fail and the poll falls back to PCM
            MP_ERR(ao, "loader requested offset %lld below the retained "
                   "window at %lld\n", (long long)off, (long long)p->es_head);
            [req finishLoadingWithError:
                [NSError errorWithDomain:NSPOSIXErrorDomain code:ESPIPE userInfo:nil]];
            [reqs removeObjectAtIndex:i];
            continue;
        }
        int64_t req_end = dr.requestsAllDataToEndOfResource
            ? INT64_MAX
            : dr.requestedOffset + (int64_t)dr.requestedLength;
        int64_t write_head = p->es_head + p->es_len;
        if (off < write_head) {
            // real stream data
            int64_t n = MPMIN(write_head - off, req_end - off);
            NSData *chunk = [NSData dataWithBytes:p->es_buf + (off - p->es_head)
                                           length:n];
            [dr respondWithData:chunk];
            MP_TRACE(ao, "served %lld bytes at offset %lld\n",
                     (long long)n, (long long)off);
        } else if (off > write_head && p->au_len > 0) {
            // Far-offset probe past the write head: duration/bitrate
            // estimation reading near the "end" of the endless resource.
            // Satisfy it with copies of the latest access unit; playback
            // starts at zero and never reaches these offsets.
            int64_t n = MPMIN(req_end - off, 256 * 1024);
            NSMutableData *chunk = [NSMutableData dataWithCapacity:n];
            while ((int64_t)chunk.length + p->au_len <= n)
                [chunk appendBytes:p->au_buf length:p->au_len];
            if (chunk.length == 0)
                [chunk appendBytes:p->au_buf length:MPMIN(p->au_len, n)];
            if (chunk.length > n)
                [chunk setLength:n];
            [dr respondWithData:chunk];
            MP_VERBOSE(ao, "synthesized %lu probe bytes at offset %lld\n",
                       (unsigned long)chunk.length, (long long)off);
        }
        if (!dr.requestsAllDataToEndOfResource &&
            dr.currentOffset >= dr.requestedOffset + (int64_t)dr.requestedLength) {
            [req finishLoading];
            [reqs removeObjectAtIndex:i];
            continue;
        }
        i++;
    }

    // drop history beyond the retention bound
    int64_t low = p->es_head + p->es_len;
    for (AVAssetResourceLoadingRequest *req in reqs)
        low = MPMIN(low, req.dataRequest.currentOffset);
    int64_t drop = (low - AVP_ES_HISTORY_BYTES) - p->es_head;
    if (drop > 0) {
        memmove(p->es_buf, p->es_buf + drop, p->es_len - drop);
        p->es_head += drop;
        p->es_len -= drop;
    }
}

// Apply the desired transport state, with the startup workaround: prime the
// player, and when the playhead refuses to move, first seek to the stream
// start, then give up and fall back to PCM.
static void avp_update_transport(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!p->avp_playing || !p->item || p->spdif_reload_requested)
        return;
    int64_t now = mp_time_ns();
    if (!p->avp_rate_applied) {
        bool primed = p->es_pts >= AVP_START_MIN_NS || p->avp_eof;
        if (!primed) {
            // the startup clock starts once the stream is primed
            p->avp_start_deadline = now + AVP_START_GRACE_NS;
            return;
        }
        // Not gated on the item becoming ready: while prerolling, the
        // system may park on a far-offset probe of the fake endless
        // resource that can never be served, and only the seek-to-start
        // workaround below can break that; readiness follows the seek.
        [p->player setRate:1];
        p->avp_rate_applied = true;
        p->avp_start_deadline = now + AVP_START_GRACE_NS;
        return;
    }
    if (p->avp_start_deadline < 0)
        return;
    if (avp_current_time_ns(ao) > 0) {
        p->avp_start_deadline = -1; // playing; nothing left to supervise
        return;
    }
    // A source that cannot outpace realtime (a realtime-pinned or
    // CPU-bound server transcode) trickles preroll in slowly; a hard
    // deadline would abandon it for PCM within seconds. Keep waiting while
    // priming is still making progress, like a blocking loader would: the
    // pipeline engages once preroll is satisfied, just late. The startup
    // gate bounds this -- a parked player keeps pulling at full speed,
    // tops the gate out quickly, progress stops, and the deadline below
    // resumes its work.
    if (p->es_pts > p->avp_primed_pts && p->es_pts < AVP_START_LEAD_NS(p)) {
        p->avp_primed_pts = p->es_pts;
        p->avp_start_deadline = now + AVP_START_GRACE_NS;
        return;
    }
    if (now < p->avp_start_deadline)
        return;
    if (!p->avp_start_seeked) {
        MP_WARN(ao, "playback did not engage; seeking to the stream start\n");
        p->avp_start_seeked = true;
        p->avp_start_deadline = now + AVP_START_GRACE_NS;
        [p->item seekToTime:kCMTimeZero completionHandler:nil];
        [p->player setRate:1];
        return;
    }
    MP_ERR(ao, "native compressed playback did not start; falling back to PCM\n");
    spdif_reload(ao);
}

// Main driver for the compressed sink; runs on p->queue (timer tick or a
// new loading request).
static void feed_avp(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->spdif_reload_requested || !p->item)
        return;

    // surface player/item state transitions while diagnosing startup
    int item_status = (int)[p->item status];
    int tcs = (int)[p->player timeControlStatus];
    if (item_status != p->avp_last_item_status || tcs != p->avp_last_tcs) {
        MP_VERBOSE(ao, "item status %d -> %d, time control %d -> %d, "
                   "pos %.3fs, fed %.3fs\n",
                   p->avp_last_item_status, item_status,
                   p->avp_last_tcs, tcs,
                   avp_current_time_ns(ao) / 1e9, p->es_pts / 1e9);
        p->avp_last_item_status = item_status;
        p->avp_last_tcs = tcs;
    }
    if (++p->avp_heartbeat % 100 == 0) {
        CMTime t = [p->item currentTime];
        int64_t write_head = p->es_head + p->es_len;
        int64_t reader_gap = -1;
        for (AVAssetResourceLoadingRequest *req in p->loader->requests) {
            AVAssetResourceLoadingDataRequest *dr = req.dataRequest;
            if (!dr || dr.currentOffset > write_head)
                continue;
            int64_t gap = write_head - dr.currentOffset;
            if (reader_gap < 0 || gap < reader_gap)
                reader_gap = gap;
        }
        MP_VERBOSE(ao, "heartbeat: raw pos %.3fs, clamped %.3fs, fed %.3fs, "
                   "status %d, tc %d, reader gap %lld B\n",
                   CMTIME_IS_NUMERIC(t) ? CMTimeGetNanoseconds(t) / 1e9 : -1.0,
                   avp_current_time_ns(ao) / 1e9, p->es_pts / 1e9,
                   item_status, tcs, (long long)reader_gap);
    }
    if ([p->item status] == AVPlayerItemStatusFailed || [p->player error]) {
        NSError *error = [p->item error] ? [p->item error] : [p->player error];
        MP_ERR(ao, "player rejected the compressed stream: %s (%s:%ld)\n",
               error ? error.localizedDescription.UTF8String : "unknown",
               error ? error.domain.UTF8String : "-",
               error ? (long)error.code : 0);
        MP_ERR(ao, "falling back to PCM\n");
        spdif_reload(ao);
        return;
    }

    for (int guard = 0; guard < 64 && !p->avp_eof; guard++) {
        int64_t cur = avp_feed_position_ns(ao);
        if (p->es_pts - cur >= (cur > 0 ? p->avp_lead_ns : AVP_START_LEAD_NS(p)))
            break;
        // One pull can extract every burst buffered in the stash, so demand
        // room for a full stash's worth of payload before pulling.
        if (p->es_size - p->es_len < p->stash_size)
            break; // backpressure; serving will trim the window
        if (!avp_pull(ao))
            break;
    }
    if (p->spdif_reload_requested)
        return;
    avp_serve_requests(ao);
    avp_update_transport(ao);
}

// Build a fresh asset/item pair. An elementary stream cannot signal
// discontinuities, so every stream restart (seek, track change) starts a
// new item at offset 0 / time 0.
static void avp_create_item(struct ao *ao)
{
    struct priv *p = ao->priv;

    NSString *urlstr = [NSString stringWithFormat:@"mpv-passthrough://stream/audio.%s",
                        p->spdif_ext];
    NSURL *url = [NSURL URLWithString:urlstr];
    p->asset = [[AVURLAsset alloc] initWithURL:url options:nil];
    [p->asset.resourceLoader setDelegate:p->loader queue:p->queue];
    p->item = [[AVPlayerItem alloc] initWithAsset:p->asset];
    p->item.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
    [p->player replaceCurrentItemWithPlayerItem:p->item];

    p->stash_len = 0;
    p->es_len = 0;
    p->es_head = 0;
    p->es_pts = 0;
    p->pulled_samples = 0;
    p->es_dropped_ns = 0;
    p->avp_eof = false;
    p->avp_rate_applied = false;
    p->avp_start_seeked = false;
    p->avp_primed_pts = 0;
    p->avp_start_deadline = mp_time_ns() + AVP_READY_GRACE_NS;
    p->au_len = 0;
    p->avp_last_item_status = -1;
    p->avp_last_tcs = -1;
}

static void avp_teardown_item(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!p->item)
        return;
    [p->player setRate:0];
    for (AVAssetResourceLoadingRequest *req in p->loader->requests) {
        if (!req.finished && !req.cancelled)
            [req finishLoadingWithError:
                [NSError errorWithDomain:NSURLErrorDomain
                                    code:NSURLErrorCancelled userInfo:nil]];
    }
    [p->loader->requests removeAllObjects];
    [p->asset.resourceLoader setDelegate:nil queue:nil];
    [p->player replaceCurrentItemWithPlayerItem:nil];
    [p->item release];
    p->item = nil;
    [p->asset release];
    p->asset = nil;
    p->stash_len = 0;
    p->es_len = 0;
    p->es_head = 0;
    p->es_pts = 0;
    p->pulled_samples = 0;
    p->es_dropped_ns = 0;
    p->avp_eof = false;
    p->avp_rate_applied = false;
    p->avp_start_seeked = false;
    p->avp_primed_pts = 0;
    p->au_len = 0;
}

#if TARGET_OS_OSX
static void feed(struct ao *ao);

static void pcm_request_media_data(struct ao *ao)
{
    struct priv *p = ao->priv;
    [p->renderer requestMediaDataWhenReadyOnQueue:p->queue usingBlock:^{
        feed(ao);
    }];
}

// Idle the one-shot timer. Runs on p->queue, or on the player thread while
// the queue is blocked in stop()/uninit(), so it never races the handler.
static void pcm_cancel_pending_feed(struct priv *p)
{
    if (p->feed_timer) {
        dispatch_source_set_timer(p->feed_timer, DISPATCH_TIME_FOREVER,
                                  DISPATCH_TIME_FOREVER, 0);
    }
}

// Stop feeding until the queue has drained back under the bound.
//
// Returning from the request block without enqueueing would spin instead of
// waiting: the header has the block run "until the receiver's
// readyForMoreMediaData property becomes NO or until there is no more data to
// supply", and the renderer re-invokes it once it "becomes ready for more
// media data again" -- an edge that never comes while it is already ready and
// we are simply refusing to feed. So disarm and come back on a timer.
static void pcm_pause_feeding(struct ao *ao)
{
    struct priv *p = ao->priv;

    [p->renderer stopRequestingMediaData];
    if (!p->feed_enabled)
        return;
    if (!p->feed_timer) {
        // No timer to wake us: keep the renderer fed rather than stall.
        pcm_request_media_data(ao);
        return;
    }
    dispatch_source_set_timer(
        p->feed_timer,
        dispatch_time(DISPATCH_TIME_NOW, p->pcm_lookahead_ns / 2),
        DISPATCH_TIME_FOREVER, p->pcm_lookahead_ns / 10);
}

// Turn the bounded PCM feed on or off. Serialized on p->queue so it cannot
// race the timer handler; start()/stop() already hold the queue when they
// call it, hence the reentrancy check.
static void pcm_set_feeding(struct ao *ao, bool enabled)
{
    struct priv *p = ao->priv;

    void (^block)(void) = ^{
        p->feed_enabled = enabled;
        pcm_cancel_pending_feed(p);
        if (enabled) {
            pcm_request_media_data(ao);
        } else {
            [p->renderer stopRequestingMediaData];
        }
    };
    if (dispatch_get_specific(&avfoundation_queue_key) == p)
        block();
    else
        dispatch_sync(p->queue, block);
}
#endif  // TARGET_OS_OSX

static void feed(struct ao *ao)
{
    struct priv *p = ao->priv;
    int samplerate = ao->samplerate;
    int sstride = ao->sstride;

#if TARGET_OS_OSX
    if (p->pcm_lookahead_ns) {
        int64_t now = CMTimeGetNanoseconds([p->synchronizer currentTime]);
        if (p->end_time_av - now >= p->pcm_lookahead_ns) {
            pcm_pause_feeding(ao);
            return;
        }
    }
#endif

    CMBlockBufferRef block_buffer = NULL;
    CMSampleBufferRef sample_buffer = NULL;
    OSStatus err;

    int request_sample_count = samplerate / 10;
    int buffer_size = request_sample_count * sstride;
    void *data[] = {CFAllocatorAllocate(NULL, buffer_size, 0)};

    int64_t cur_time_av = CMTimeGetNanoseconds([p->synchronizer currentTime]);
    int64_t cur_time_mp = mp_time_ns();
    int64_t end_time_av = MPMAX(p->end_time_av, cur_time_av);
    int64_t time_delta = CMTimeGetNanoseconds(CMTimeMake(request_sample_count, samplerate));
    bool eof;
    int real_sample_count = ao_read_data(ao, data, request_sample_count, end_time_av - cur_time_av + cur_time_mp + time_delta, &eof, false, true);
    if (eof) {
        [p->renderer stopRequestingMediaData];
        ao_stop_streaming(ao);
    }
    if (real_sample_count == 0) {
        goto finish;
    }

    if ((err = CMBlockBufferCreateWithMemoryBlock(
        NULL,
        data[0],
        buffer_size,
        NULL,
        NULL,
        0,
        real_sample_count * sstride,
        0,
        &block_buffer
    )) != noErr) {
        MP_FATAL(ao, "failed to create block buffer\n");
        MP_VERBOSE(ao, "CMBlockBufferCreateWithMemoryBlock returned %d\n", err);
        goto error;
    }
    data[0] = NULL;

    CMSampleTimingInfo sample_timing_into[] = {(CMSampleTimingInfo) {
        .duration = CMTimeMake(1, samplerate),
        .presentationTimeStamp = CMTimeFromNanoseconds(end_time_av),
        .decodeTimeStamp = kCMTimeInvalid
    }};
    size_t sample_size_array[] = {sstride};
    if ((err = CMSampleBufferCreateReady(
        NULL,
        block_buffer,
        p->format_description,
        real_sample_count,
        1,
        sample_timing_into,
        1,
        sample_size_array,
        &sample_buffer
    )) != noErr) {
        MP_FATAL(ao, "failed to create sample buffer\n");
        MP_VERBOSE(ao, "CMSampleBufferCreateReady returned %d\n", err);
        goto error;
    }

    [p->renderer enqueueSampleBuffer:sample_buffer];

    time_delta = CMTimeGetNanoseconds(CMTimeMake(real_sample_count, samplerate));
    p->end_time_av = end_time_av + time_delta;

    goto finish;

error:
    ao_request_reload(ao);
finish:
    if (data[0]) CFAllocatorDeallocate(NULL, data[0]);
    if (block_buffer) CFRelease(block_buffer);
    if (sample_buffer) CFRelease(sample_buffer);
}

static void start(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->spdif) {
        void (^start_block)(void) = ^{
            p->avp_playing = true;
            if (!p->item)
                avp_create_item(ao);
            else if (p->avp_rate_applied)
                [p->player setRate:1];
            avp_timer_arm(p);
            feed_avp(ao);
        };
        if (dispatch_get_specific(&avfoundation_queue_key) == p)
            start_block();
        else
            dispatch_sync(p->queue, start_block);
        return;
    }

    p->end_time_av = -1;
    [p->synchronizer setRate:1];
#if TARGET_OS_OSX
    // With no bound there is nothing to gate, so arm exactly as before rather
    // than routing the first arm through the queue.
    if (p->pcm_lookahead_ns) {
        pcm_set_feeding(ao, true);
        return;
    }
#endif
    [p->renderer requestMediaDataWhenReadyOnQueue:p->queue usingBlock:^{
        feed(ao);
    }];
}

static void stop(struct ao *ao)
{
    struct priv *p = ao->priv;

    void (^stop_block)(void) = ^{
        if (p->spdif) {
            p->avp_playing = false;
            avp_timer_idle(p);
            avp_teardown_item(ao);
            return;
        }
        [p->renderer stopRequestingMediaData];
        [p->renderer flush];
        [p->synchronizer setRate:0];
#if TARGET_OS_OSX
        // A frozen clock never drains the queue, so leave nothing scheduled;
        // start() turns feeding back on.
        p->feed_enabled = false;
        pcm_cancel_pending_feed(p);
#endif
    };
    if (dispatch_get_specific(&avfoundation_queue_key) == p)
        stop_block();
    else
        dispatch_sync(p->queue, stop_block);
}

static bool set_pause(struct ao *ao, bool paused)
{
    struct priv *p = ao->priv;

    if (p->spdif) {
        void (^pause_block)(void) = ^{
            p->avp_playing = !paused;
            if (paused) {
                avp_timer_idle(p);
                [p->player setRate:0];
            } else {
                if (p->avp_rate_applied) {
                    [p->player setRate:1];
                    if (p->avp_start_deadline >= 0)
                        p->avp_start_deadline = mp_time_ns() + AVP_START_GRACE_NS;
                } else {
                    // priming/readiness supervision resumes from now
                    p->avp_start_deadline = mp_time_ns() + AVP_READY_GRACE_NS;
                }
                avp_timer_arm(p);
                feed_avp(ao);
            }
        };
        if (dispatch_get_specific(&avfoundation_queue_key) == p)
            pause_block();
        else
            dispatch_sync(p->queue, pause_block);
        return true;
    }

    if (paused) {
        [p->synchronizer setRate:0];
#if TARGET_OS_OSX
        // The clock is stopped, so the bound can never be undercut again on
        // its own. Stop asking rather than waking every half-bound to
        // rediscover that.
        if (p->pcm_lookahead_ns)
            pcm_set_feeding(ao, false);
#endif
    } else {
#if TARGET_OS_OSX
        if (p->pcm_lookahead_ns)
            pcm_set_feeding(ao, true);
#endif
        [p->synchronizer setRate:1];
    }

    return true;
}

static int control(struct ao *ao, enum aocontrol cmd, void *arg)
{
    struct priv *p = ao->priv;

    if (p->spdif) {
        switch (cmd) {
        case AOCONTROL_GET_MUTE:
            *(bool*)arg = [p->player isMuted];
            return CONTROL_OK;
        case AOCONTROL_GET_VOLUME:
            *(float*)arg = [p->player volume] * 100;
            return CONTROL_OK;
        case AOCONTROL_SET_MUTE:
            [p->player setMuted:*(bool*)arg];
            return CONTROL_OK;
        case AOCONTROL_SET_VOLUME:
            [p->player setVolume:*(float*)arg / 100];
            return CONTROL_OK;
        default:
            return CONTROL_UNKNOWN;
        }
    }

    switch (cmd) {
    case AOCONTROL_GET_MUTE:
        *(bool*)arg = [p->renderer isMuted];
        return CONTROL_OK;
    case AOCONTROL_GET_VOLUME:
        *(float*)arg = [p->renderer volume] * 100;
        return CONTROL_OK;
    case AOCONTROL_SET_MUTE:
        [p->renderer setMuted:*(bool*)arg];
        return CONTROL_OK;
    case AOCONTROL_SET_VOLUME:
        [p->renderer setVolume:*(float*)arg / 100];
        return CONTROL_OK;
    default:
        return CONTROL_UNKNOWN;
    }
}

@implementation AVObserver
- (instancetype)initWithAO:(struct ao*)_ao {
    self = [super init];
    if (self) {
        ao = _ao;
    }
    return self;
}
- (void)handleRestartNotification:(NSNotification*)notification {
    char *name = cfstr_get_cstr((CFStringRef)notification.name);
    MP_WARN(ao, "restarting due to system notification; this will cause desync\n");
    MP_VERBOSE(ao, "notification name: %s\n", name);
    talloc_free(name);
    stop(ao);
    start(ao);
}
@end

@implementation AVPLoader
- (instancetype)initWithAO:(struct ao*)_ao {
    self = [super init];
    if (self) {
        ao = _ao;
        requests = [[NSMutableArray alloc] init];
    }
    return self;
}
// Called on p->queue (the delegate queue), like the feed timer, so no state
// here needs further locking.
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request {
    @synchronized(self) {
        if (!ao)
            return NO;
        struct priv *p = ao->priv;
        AVAssetResourceLoadingContentInformationRequest *info =
            request.contentInformationRequest;
        if (info) {
            // Declaring the UTI is what routes the stream into the system's
            // own (E-)AC-3 parser and Dolby decode path. The stream is
            // endless and strictly sequential.
            info.contentType = [NSString stringWithUTF8String:p->spdif_uti];
            info.contentLength = INT32_MAX;
            info.byteRangeAccessSupported = NO;
        }
        AVAssetResourceLoadingDataRequest *dr = request.dataRequest;
        MP_VERBOSE(ao, "loading request: info=%d data=%d offset=%lld "
                   "length=%ld allToEnd=%d\n", !!info, !!dr,
                   dr ? (long long)dr.requestedOffset : -1,
                   dr ? (long)dr.requestedLength : -1,
                   dr ? dr.requestsAllDataToEndOfResource : 0);
        if (dr) {
            [requests addObject:request];
            feed_avp(ao);
        } else {
            [request finishLoading];
        }
        return YES;
    }
}
- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)request {
    @synchronized(self) {
        [requests removeObjectIdenticalTo:request];
        if (ao)
            MP_VERBOSE((struct ao *)ao, "loading request cancelled\n");
    }
}
- (void)invalidate {
    @synchronized(self) {
        ao = NULL;
        [requests removeAllObjects];
    }
}
- (void)dealloc {
    [requests release];
    [super dealloc];
}
@end

static int init(struct ao *ao)
{
    struct priv *p = ao->priv;
    AudioChannelLayout *layout = NULL;
    bool spdif = af_fmt_is_spdif(ao->format);

    if (spdif && !p->opt_accept_compressed) {
        MP_VERBOSE(ao, "compressed audio disabled; trying next audio output\n");
        return CONTROL_ERROR;
    }

    if (!spdif) {
        atomic_store(&spdif_format_latch[0], false);
        atomic_store(&spdif_format_latch[1], false);
    }

#if TARGET_OS_IPHONE
    AVAudioSession *instance = AVAudioSession.sharedInstance;
    [instance setCategory:AVAudioSessionCategoryPlayback error:nil];
    [instance setMode:AVAudioSessionModeMoviePlayback error:nil];
#if HAVE_MACOS_12_FEATURES
    if (@available(tvOS 15.0, iOS 15.0, *)) {
        if (spdif || ao->channels.num > 2)
            [instance setSupportsMultichannelContent:YES error:nil];
    }
#endif
    [instance setActive:YES error:nil];
    NSInteger maxChannels = instance.maximumOutputNumberOfChannels;
    if (spdif) {
        AVAudioSessionPortDescription *port = instance.currentRoute.outputs.firstObject;
        MP_INFO(ao, "compressed audio route: %s, %ld maximum output channels\n",
                port ? port.portType.UTF8String : "none", (long)maxChannels);
    } else {
        NSInteger prefChannels = MIN(maxChannels, ao->channels.num);
        [instance setPreferredOutputNumberOfChannels:prefChannels error:nil];
    }
#endif

    if ((p->queue = dispatch_queue_create(
        "avfoundation event",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0)
    )) == NULL) {
        MP_FATAL(ao, "failed to create dispatch queue\n");
        MP_VERBOSE(ao, "dispatch_queue_create failed\n");
        goto error;
    }
    dispatch_queue_set_specific(p->queue, &avfoundation_queue_key, p, NULL);

    if (spdif) {
        // Hand the raw elementary stream to AVPlayer, whose pipeline is the
        // one place the system decodes E-AC-3 JOC (Dolby Atmos) and renders
        // it to the active route. Works identically for plain DD/DD+, so it
        // is used unconditionally; genuine failures fall back to PCM.
        switch (ao->format) {
        case AF_FORMAT_S_AC3:
            p->spdif_data_type = IEC61937_AC3;
            // ad_spdif emits AC3 as a 1x rate IEC 61937 stream
            p->spdif_rate = ao->samplerate;
            p->spdif_burst_size = 6144;
            p->spdif_uti = "public.ac3-audio";
            p->spdif_ext = "ac3";
            break;
        case AF_FORMAT_S_EAC3:
            p->spdif_data_type = IEC61937_EAC3;
            // ad_spdif emits EAC3 as a 4x rate IEC 61937 stream
            p->spdif_rate = ao->samplerate / 4;
            p->spdif_burst_size = 24576;
            p->spdif_uti = "public.enhanced-ac3-audio";
            p->spdif_ext = "eac3";
            break;
        default:
            MP_FATAL(ao, "avfoundation only supports AC3 and EAC3 passthrough\n");
#if HAVE_COREAUDIO
            MP_FATAL(ao, "please use coreaudio_exclusive instead\n");
#endif
            goto error;
        }
        if (atomic_load(&spdif_format_latch[spdif_latch_index(ao->format)])) {
            MP_FATAL(ao, "%s passthrough disabled after an earlier player failure\n",
                     af_fmt_to_str(ao->format));
            goto error;
        }
        p->spdif = true;

        if ((p->player = [[AVPlayer alloc] init]) == nil) {
            MP_FATAL(ao, "failed to create AVPlayer\n");
            goto error;
        }
        // Transport is supervised here (priming, start workaround); the
        // player must not second-guess it against a fake endless resource.
        p->player.automaticallyWaitsToMinimizeStalling = NO;
        p->player.allowsExternalPlayback = NO;
        p->loader = [[AVPLoader alloc] initWithAO:ao];
        if ((p->avp_timer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0, p->queue)) == NULL) {
            MP_FATAL(ao, "failed to create feed timer\n");
            goto error;
        }
        dispatch_source_set_event_handler(p->avp_timer, ^{
            feed_avp(ao);
        });
        avp_timer_idle(p);
        // Left resumed for its whole life: releasing a suspended source
        // traps, and an idle timer costs nothing.
        dispatch_resume(p->avp_timer);

        p->avp_lead_ns = (int64_t)(p->opt_compressed_lead * 1e9);

        // 100ms of IEC data per pull plus room for carried-over bursts
        p->stash_size = (ao->samplerate / 10) * af_fmt_to_bytes(ao->format) *
                        ao->channels.num + p->spdif_burst_size * 4;
        p->stash = talloc_size(ao, p->stash_size);
        // history + the time-bounded startup lead at the highest legal
        // EAC3 rate + slack
        p->es_size = AVP_ES_HISTORY_BYTES + 1024 * 1024 +
                     (int)(2 * p->opt_compressed_lead * AVP_ES_LEAD_BYTES_PER_S);
        p->es_buf = talloc_size(ao, p->es_size);
        p->au_buf = talloc_size(ao, p->spdif_burst_size);

        // the lead bound is what actually paces the stream
        ao->device_buffer = ao->samplerate * 2;

        return CONTROL_OK;
    }

    if ((p->renderer = [[AVSampleBufferAudioRenderer alloc] init]) == nil) {
        MP_FATAL(ao, "failed to create audio renderer\n");
        MP_VERBOSE(ao, "AVSampleBufferAudioRenderer failed to initialize\n");
        goto error;
    }
    if ((p->synchronizer = [[AVSampleBufferRenderSynchronizer alloc] init]) == nil) {
        MP_FATAL(ao, "failed to create rendering synchronizer\n");
        MP_VERBOSE(ao, "AVSampleBufferRenderSynchronizer failed to initialize\n");
        goto error;
    }

#if TARGET_OS_OSX
    // --audio-buffer is documented as a minimum the device may exceed, so it
    // cannot double as this maximum; it only keeps the bound from dropping
    // under what the core was told to expect.
    if (p->opt_max_lookahead > 0) {
        p->pcm_lookahead_ns =
            (int64_t)(MPMAX(p->opt_max_lookahead, ao->def_buffer) * 1e9);
        p->feed_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                               p->queue);
        if (p->feed_timer) {
            dispatch_source_set_event_handler(p->feed_timer, ^{
                pcm_cancel_pending_feed(p);  // one-shot: idle before refeeding
                // A stop or pause may have landed between the fire and here.
                if (p->feed_enabled)
                    pcm_request_media_data(ao);
            });
            dispatch_source_set_timer(p->feed_timer, DISPATCH_TIME_FOREVER,
                                      DISPATCH_TIME_FOREVER, 0);
            // Left resumed for its whole life: releasing a suspended source
            // traps, and an idle timer costs nothing.
            dispatch_resume(p->feed_timer);
        } else {
            MP_WARN(ao, "no timer available; leaving the renderer's own "
                        "buffer depth alone\n");
            p->pcm_lookahead_ns = 0;
        }
    }
#endif

    if (ao->device && ao->device[0]) {
#if TARGET_OS_OSX
        [p->renderer setAudioOutputDeviceUniqueID:(NSString*)cfstr_from_cstr(ao->device)];
#endif
    }

    [p->synchronizer addRenderer:p->renderer];
#if HAVE_MACOS_11_3_FEATURES
    if (@available(tvOS 14.5, iOS 14.5, macOS 11.3, *)) {
        [p->synchronizer setDelaysRateChangeUntilHasSufficientMediaData:NO];
    }
#endif

    // AVSampleBufferAudioRenderer only supports interleaved formats
    ao->format = af_fmt_from_planar(ao->format);
    if (af_fmt_is_planar(ao->format)) {
        MP_FATAL(ao, "planar audio formats are unsupported\n");
        goto error;
    }

    AudioStreamBasicDescription asbd;
    ca_fill_asbd(ao, &asbd);
    size_t layout_size;
    layout = ca_get_acl(ao, &layout_size);

    OSStatus err;
    if ((err = CMAudioFormatDescriptionCreate(
        NULL,
        &asbd,
        layout_size,
        layout,
        0,
        NULL,
        NULL,
        &p->format_description
    )) != noErr) {
        MP_FATAL(ao, "failed to create audio format description\n");
        MP_VERBOSE(ao, "CMAudioFormatDescriptionCreate returned %d\n", err);
        goto error;
    }
    talloc_free(layout);
    layout = NULL;

    // AVSampleBufferAudioRenderer read ahead aggressively
    ao->device_buffer = ao->samplerate * 2;

    p->observer = [[AVObserver alloc] initWithAO:ao];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
#if HAVE_MACOS_12_FEATURES
    if (@available(tvOS 15.0, iOS 15.0, macOS 12.0, *)) {
        [center addObserver:p->observer selector:@selector(handleRestartNotification:) name:AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification object:p->renderer];
    }
#endif
    [center addObserver:p->observer selector:@selector(handleRestartNotification:) name:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification object:p->renderer];

    return CONTROL_OK;

error:
    talloc_free(layout);
    if (p->avp_timer) {
        dispatch_source_cancel(p->avp_timer);
        dispatch_release(p->avp_timer);
        p->avp_timer = NULL;
    }
#if TARGET_OS_OSX
    if (p->feed_timer) {
        dispatch_source_cancel(p->feed_timer);
        dispatch_release(p->feed_timer);
        p->feed_timer = NULL;
    }
#endif
    if (p->loader) {
        [p->loader invalidate];
        [p->loader release];
    }
    if (p->player) [p->player release];
    if (p->renderer) [p->renderer release];
    if (p->synchronizer) [p->synchronizer release];
    if (p->queue) dispatch_release(p->queue);
    if (p->format_description) CFRelease(p->format_description);

#if TARGET_OS_IPHONE
    [AVAudioSession.sharedInstance setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
        error:nil
    ];
#endif

    return CONTROL_ERROR;
}

static void uninit(struct ao *ao)
{
    struct priv *p = ao->priv;

    stop(ao);

    if (p->spdif) {
        // The timer handler dereferences the AO, and ao_uninit() frees it as
        // soon as this returns. Cancelling on p->queue means no handler is
        // mid-flight and none can start afterwards.
        dispatch_sync(p->queue, ^{
            dispatch_source_cancel(p->avp_timer);
            [p->loader invalidate];
        });
        dispatch_release(p->avp_timer);
        [p->loader release];
        [p->player release];
        dispatch_release(p->queue);
    } else {
        // The handler dereferences the AO, and ao_uninit() frees it as soon
        // as this returns. Cancelling on p->queue means no handler is
        // mid-flight and none can start afterwards. stop() above already
        // left the timer idle.
#if TARGET_OS_OSX
        if (p->feed_timer) {
            dispatch_sync(p->queue, ^{
                dispatch_source_cancel(p->feed_timer);
            });
            dispatch_release(p->feed_timer);
            p->feed_timer = NULL;
        }
#endif
        [p->renderer release];
        [p->synchronizer release];
        dispatch_release(p->queue);
        CFRelease(p->format_description);

        [[NSNotificationCenter defaultCenter] removeObserver:p->observer];
        [p->observer release];
    }

#if TARGET_OS_IPHONE
    [AVAudioSession.sharedInstance setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
        error:nil
    ];
#endif
}

#define OPT_BASE_STRUCT struct priv

const struct ao_driver audio_out_avfoundation = {
    .description    = "AVFoundation AVSampleBufferAudioRenderer / AVPlayer",
    .name           = "avfoundation",
    .uninit         = uninit,
    .init           = init,
    .control        = control,
    .reset          = stop,
    .start          = start,
    .set_pause      = set_pause,
    .list_devs      = ca_get_device_list,
    .priv_size      = sizeof(struct priv),
    .priv_defaults  = &(const struct priv){
        .opt_accept_compressed = true,
        .opt_compressed_lead = 8,
        // Well inside the renderer's own depth, so the queue still absorbs
        // scheduling jitter, while cutting the delay before a volume change
        // is audible to a fraction of what it was.
#if TARGET_OS_OSX
        .opt_max_lookahead = 0.5,
#endif
    },
    .options = (const struct m_option[]) {
#if TARGET_OS_OSX
        {"max-lookahead", OPT_DOUBLE(opt_max_lookahead), M_RANGE(0, 10)},
#endif
        {"accept-compressed", OPT_BOOL(opt_accept_compressed)},
        {"compressed-lead", OPT_DOUBLE(opt_compressed_lead), M_RANGE(1, 30)},
        {0}
    },
    .options_prefix = "ao-avfoundation",
};
