#include <iostream>
#include <string>
#include <optional>
#include <chrono>

#define SDL_MAIN_HANDLED
#include <SDL.h>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/hwcontext.h>
#include <libswscale/swscale.h>
}

static inline int64_t now_us() {
    using namespace std::chrono;
    return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

struct Args {
    std::string url = "tcp://127.0.0.1:5000?tcp_nodelay=1";
    bool prefer_gpu = true;
    int target_fps = 0;        // 0 = pas de verrouillage cadence
    bool drop_when_late = true;
};

static void usage(const char* exe) {
    std::cout <<
        "Usage: " << exe << " [--url <tcp_url>] [--cpu] [--fps N] [--no-drop]\n"
        "  --url tcp://127.0.0.1:5000?tcp_nodelay=1\n"
        "  --cpu           force CPU (fallback)\n"
        "  --fps N         cadence d'affichage (sinon horloge murale)\n"
        "  --no-drop       n'abandonne pas si on est en avance/retard\n";
}

static std::optional<Args> parse_args(int argc, char** argv) {
    Args a;
    for (int i=1; i<argc; ++i) {
        std::string v = argv[i];
        if (v=="--help" || v=="-h") { usage(argv[0]); return std::nullopt; }
        else if (v=="--url" && i+1<argc) a.url = argv[++i];
        else if (v=="--cpu") a.prefer_gpu = false;
        else if (v=="--fps" && i+1<argc) a.target_fps = std::stoi(argv[++i]);
        else if (v=="--no-drop") a.drop_when_late = false;
        else { std::cerr << "Unknown arg: " << v << "\n"; usage(argv[0]); return std::nullopt; }
    }
    return a;
}

// NVDEC helpers
static AVPixelFormat hw_pix_fmt = AV_PIX_FMT_NONE;
static enum AVPixelFormat get_hw_format(AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts) {
    for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == hw_pix_fmt) return *p;
    }
    std::cerr << "HW pixel format not available.\n";
    return AV_PIX_FMT_NONE;
}

int main(int argc, char** argv) {
    auto pargs = parse_args(argc, argv);
    if (!pargs.has_value()) return 0;
    Args args = *pargs;

    av_log_set_level(AV_LOG_ERROR);
    avformat_network_init();

    AVFormatContext* fmt = avformat_alloc_context();
    if (!fmt) { std::cerr << "Alloc fmt failed\n"; return 1; }
    fmt->flags |= AVFMT_FLAG_NOBUFFER;

    AVDictionary* fmt_opts = nullptr;
    av_dict_set(&fmt_opts, "probesize", "131072", 0);
    av_dict_set(&fmt_opts, "analyzeduration", "0", 0);

    if (avformat_open_input(&fmt, args.url.c_str(), nullptr, &fmt_opts) < 0) {
        std::cerr << "avformat_open_input failed\n"; return 1;
    }
    av_dict_free(&fmt_opts);

    if (avformat_find_stream_info(fmt, nullptr) < 0) {
        std::cerr << "avformat_find_stream_info failed\n"; return 1;
    }

    int vstream = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (vstream < 0) { std::cerr << "No video stream\n"; return 1; }
    AVStream* st = fmt->streams[vstream];

    // Choix du codec
    AVCodec* codec = nullptr;
    AVCodec* cuvid = nullptr;
    if (args.prefer_gpu) {
        cuvid = avcodec_find_decoder_by_name("h264_cuvid");
        if (cuvid) codec = cuvid;
    }
    if (!codec) {
        codec = avcodec_find_decoder(st->codecpar->codec_id);
        if (!codec) { std::cerr << "No decoder found\n"; return 1; }
        if (args.prefer_gpu) std::cerr << "[Info] NVDEC not available, CPU fallback.\n";
    }

    AVCodecContext* dec = avcodec_alloc_context3(codec);
    if (!dec) { std::cerr << "Alloc codec ctx failed\n"; return 1; }
    if (avcodec_parameters_to_context(dec, st->codecpar) < 0) {
        std::cerr << "parameters_to_context failed\n"; return 1;
    }
    dec->flags  |= AV_CODEC_FLAG_LOW_DELAY;
    dec->flags2 |= AV_CODEC_FLAG2_FAST;

    // NVDEC device
    AVBufferRef* hw_dev = nullptr;
    if (cuvid) {
        if (av_hwdevice_ctx_create(&hw_dev, AV_HWDEVICE_TYPE_CUDA, nullptr, nullptr, 0) < 0) {
            std::cerr << "CUDA hwdevice create failed, CPU fallback.\n";
            cuvid = nullptr;
        } else {
            dec->hw_device_ctx = av_buffer_ref(hw_dev);
            hw_pix_fmt = AV_PIX_FMT_CUDA;
            dec->get_format = get_hw_format;
            av_opt_set_int(dec, "extra_hw_frames", 0, 0);
        }
    } else {
        // CPU : 1 thread = latence mini (tu peux mettre 0 pour auto si tu préfères)
        dec->thread_count = 1;
    }

    if (avcodec_open2(dec, codec, nullptr) < 0) {
        std::cerr << "avcodec_open2 failed\n"; return 1;
    }

    // --- SDL ---
    SDL_SetMainReady();
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_EVENTS) != 0) {
        std::cerr << "SDL_Init failed: " << SDL_GetError() << "\n"; return 1;
    }
    int W = dec->width  > 0 ? dec->width  : 1920;
    int H = dec->height > 0 ? dec->height : 1080;

    SDL_Window* win = SDL_CreateWindow("WinLLPlay (NVDEC low-latency)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        W, H, SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    if (!win) { std::cerr << "SDL_CreateWindow failed\n"; return 1; }

    SDL_Renderer* ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    if (!ren) { std::cerr << "SDL_CreateRenderer failed\n"; return 1; }

    SDL_Texture* tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_IYUV,
                                         SDL_TEXTUREACCESS_STREAMING, W, H);
    if (!tex) { std::cerr << "SDL_CreateTexture failed\n"; return 1; }

    SwsContext* sws = nullptr;

    auto alloc_tex = [&](int w, int h) {
        if (tex) SDL_DestroyTexture(tex);
        tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_IYUV,
                                SDL_TEXTUREACCESS_STREAMING, w, h);
        return tex != nullptr;
    };

    AVPacket* pkt = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();     // GPU (CUDA) ou CPU selon cas
    AVFrame* sw_frame = av_frame_alloc();  // CPU (après transfert depuis GPU)
    AVFrame* yuv420p = av_frame_alloc();   // CPU (I420 pour SDL)

    auto alloc_yuv420p = [&](int w, int h) {
        av_frame_unref(yuv420p);
        yuv420p->format = AV_PIX_FMT_YUV420P;
        yuv420p->width = w;
        yuv420p->height = h;
        return av_frame_get_buffer(yuv420p, 32) == 0;
    };
    if (!pkt || !frame || !sw_frame || !yuv420p || !alloc_yuv420p(W,H)) {
        std::cerr << "Frame/packet alloc failed\n"; return 1;
    }

    bool running = true;
    int64_t last_present_us = now_us();
    const double target_interval_us = (args.target_fps > 0) ? (1e6 / args.target_fps) : 0.0;

    std::cout << "URL: " << args.url << "\n"
              << "Decoder: " << dec->codec->name << (cuvid ? " (NVDEC)" : " (CPU)") << "\n";

    while (running) {
        // input non-bloquant côté SDL
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = false;
            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_q) running = false;
        }

        if (av_read_frame(fmt, pkt) < 0) {
            SDL_Delay(1);
            continue;
        }
        if (pkt->stream_index != vstream) {
            av_packet_unref(pkt);
            continue;
        }

        if (avcodec_send_packet(dec, pkt) < 0) {
            av_packet_unref(pkt);
            continue;
        }
        av_packet_unref(pkt);

        while (true) {
            int ret = avcodec_receive_frame(dec, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;

            int w = frame->width, h = frame->height;
            if (w != W || h != H) {
                W = w; H = h;
                if (!alloc_tex(W,H) || !alloc_yuv420p(W,H)) { running = false; break; }
                if (sws) { sws_freeContext(sws); sws = nullptr; }
            }

            AVFrame* src = nullptr;
            AVPixelFormat src_fmt;
            if (cuvid && frame->format == AV_PIX_FMT_CUDA) {
                av_frame_unref(sw_frame);
                if (av_hwframe_transfer_data(sw_frame, frame, 0) < 0) {
                    av_frame_unref(frame);
                    continue; // drop
                }
                src = sw_frame;
                src_fmt = (AVPixelFormat)sw_frame->format; // NV12 attendu
            } else {
                src = frame;
                src_fmt = (AVPixelFormat)frame->format;    // CPU
            }

            if (!sws) {
                sws = sws_getCachedContext(nullptr, W, H, src_fmt, W, H,
                                            AV_PIX_FMT_YUV420P, SWS_POINT, nullptr, nullptr, nullptr);
                if (!sws) { std::cerr << "sws_getCachedContext failed\n"; running = false; break; }
            }

            uint8_t* src_data[4]; int src_linesize[4];
            for (int i=0;i<4;i++){ src_data[i]=src->data[i]; src_linesize[i]=src->linesize[i]; }

            if (sws_scale(sws, src_data, src_linesize, 0, H, yuv420p->data, yuv420p->linesize) <= 0) {
                av_frame_unref(frame);
                continue;
            }

            bool render = true;
            if (args.target_fps > 0) {
                double elapsed = (double)(now_us() - last_present_us);
                if (elapsed < target_interval_us) {
                    if (args.drop_when_late) render = false; // drop pour coller à la latence mini
                    else {
                        int wait_ms = (int)((target_interval_us - elapsed)/1000.0);
                        if (wait_ms>0 && wait_ms<10) SDL_Delay(wait_ms);
                    }
                }
            }

            if (render) {
                last_present_us = now_us();
                SDL_UpdateYUVTexture(tex, nullptr,
                                     yuv420p->data[0], yuv420p->linesize[0],
                                     yuv420p->data[1], yuv420p->linesize[1],
                                     yuv420p->data[2], yuv420p->linesize[2]);
                SDL_RenderClear(ren);
                SDL_RenderCopy(ren, tex, nullptr, nullptr);
                SDL_RenderPresent(ren);
            }

            av_frame_unref(frame);
        }
    }

    // cleanup
    av_packet_free(&pkt);
    av_frame_free(&frame);
    av_frame_free(&sw_frame);
    av_frame_free(&yuv420p);
    if (sws) sws_freeContext(sws);
    if (dec) avcodec_free_context(&dec);
    if (fmt) avformat_close_input(&fmt);
    if (hw_dev) av_buffer_unref(&hw_dev);

    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}