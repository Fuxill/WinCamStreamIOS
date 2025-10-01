// main.cpp
// Build against recent FFmpeg (>= n4.4/5.x/6.x).
// MSVC: assure-toi d’avoir les include/lib FFmpeg dans les paths de ton projet.

extern "C" {
    #include <libavformat/avformat.h>
    #include <libavcodec/avcodec.h>
    #include <libswresample/swresample.h>
    #include <libswscale/swscale.h>
    #include <libavutil/imgutils.h>
    #include <libavutil/opt.h>
    }
    
    #include <iostream>
    #include <string>
    #include <stdexcept>
    #include <vector>
    #include <cstdio>
    
    static void fail(const std::string& what, int err) {
        char buf[256];
        av_strerror(err, buf, sizeof(buf));
        std::cerr << what << " failed: " << buf << " (" << err << ")\n";
        throw std::runtime_error(what);
    }
    
    static void log_stream_info(AVFormatContext* fmt, int stream_index) {
        if (stream_index < 0 || stream_index >= (int)fmt->nb_streams) return;
        AVStream* st = fmt->streams[stream_index];
        AVRational tb = st->time_base;
        std::cerr << "Stream #" << stream_index
                  << " codec_id=" << st->codecpar->codec_id
                  << " tb=" << tb.num << "/" << tb.den << "\n";
    }
    
    int main(int argc, char** argv) {
        if (argc < 2) {
            std::cout << "Usage: WinLLPlay <input>\n";
            return 0;
        }
        std::string input = argv[1];
    
        av_log_set_level(AV_LOG_ERROR);
        avformat_network_init();
    
        int err = 0;
    
        AVFormatContext* fmt = nullptr;
        if ((err = avformat_open_input(&fmt, input.c_str(), nullptr, nullptr)) < 0) {
            fail("avformat_open_input", err);
        }
        if ((err = avformat_find_stream_info(fmt, nullptr)) < 0) {
            fail("avformat_find_stream_info", err);
        }
    
        int vstream = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        int astream = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, vstream, nullptr, 0);
    
        if (vstream < 0 && astream < 0) {
            std::cerr << "No audio/video streams found.\n";
            avformat_close_input(&fmt);
            return 1;
        }
    
        log_stream_info(fmt, vstream);
        log_stream_info(fmt, astream);
    
        // ---- Video codec open ----
        AVCodecContext* vctx = nullptr;
        const AVCodec* vcodec = nullptr;
        if (vstream >= 0) {
            AVStream* vs = fmt->streams[vstream];
            vcodec = avcodec_find_decoder(vs->codecpar->codec_id); // const AVCodec*
            if (!vcodec) {
                std::cerr << "Video decoder not found.\n";
            } else {
                vctx = avcodec_alloc_context3(vcodec);
                if (!vctx) fail("avcodec_alloc_context3(video)", AVERROR(ENOMEM));
                if ((err = avcodec_parameters_to_context(vctx, vs->codecpar)) < 0) {
                    fail("avcodec_parameters_to_context(video)", err);
                }
                // Optional low-latency hints
                vctx->thread_count = 0; // auto
                av_opt_set_int(vctx, "flags2", AV_CODEC_FLAG2_FAST, 0);
                if ((err = avcodec_open2(vctx, vcodec, nullptr)) < 0) {
                    fail("avcodec_open2(video)", err);
                }
            }
        }
    
        // ---- Audio codec open ----
        AVCodecContext* actx = nullptr;
        const AVCodec* acodec = nullptr;
        if (astream >= 0) {
            AVStream* as = fmt->streams[astream];
            acodec = avcodec_find_decoder(as->codecpar->codec_id); // const AVCodec*
            if (!acodec) {
                std::cerr << "Audio decoder not found.\n";
            } else {
                actx = avcodec_alloc_context3(acodec);
                if (!actx) fail("avcodec_alloc_context3(audio)", AVERROR(ENOMEM));
                if ((err = avcodec_parameters_to_context(actx, as->codecpar)) < 0) {
                    fail("avcodec_parameters_to_context(audio)", err);
                }
                // Low-latency flags if needed
                if ((err = avcodec_open2(actx, acodec, nullptr)) < 0) {
                    fail("avcodec_open2(audio)", err);
                }
            }
        }
    
        // Frames & packet
        AVPacket* pkt = av_packet_alloc();
        AVFrame* vframe = av_frame_alloc();
        AVFrame* aframe = av_frame_alloc();
        if (!pkt || !vframe || !aframe) fail("alloc frames/packet", AVERROR(ENOMEM));
    
        // Simple read/decode loop (limited count to keep example short)
        int decoded_video = 0, decoded_audio = 0;
        const int MAX_V_FRAMES = 50;
        const int MAX_A_FRAMES = 200;
    
        while ((err = av_read_frame(fmt, pkt)) >= 0) {
            if (pkt->stream_index == vstream && vctx) {
                if ((err = avcodec_send_packet(vctx, pkt)) == 0) {
                    while ((err = avcodec_receive_frame(vctx, vframe)) == 0) {
                        AVRational tb = fmt->streams[vstream]->time_base;
                        double pts_sec = (vframe->best_effort_timestamp == AV_NOPTS_VALUE)
                                             ? 0.0
                                             : vframe->best_effort_timestamp * av_q2d(tb);
                        std::cout << "[V] frame " << decoded_video
                                  << " pts=" << pts_sec
                                  << " " << vframe->width << "x" << vframe->height
                                  << " fmt=" << vframe->format << "\n";
                        decoded_video++;
                        if (decoded_video >= MAX_V_FRAMES) break;
                    }
                    if (err == AVERROR(EAGAIN) || err == AVERROR_EOF) {
                        // need more packets or drained
                    } else if (err < 0) {
                        fail("avcodec_receive_frame(video)", err);
                    }
                } else if (err != AVERROR(EAGAIN)) {
                    fail("avcodec_send_packet(video)", err);
                }
            } else if (pkt->stream_index == astream && actx) {
                if ((err = avcodec_send_packet(actx, pkt)) == 0) {
                    while ((err = avcodec_receive_frame(actx, aframe)) == 0) {
                        AVRational tb = fmt->streams[astream]->time_base;
                        double pts_sec = (aframe->best_effort_timestamp == AV_NOPTS_VALUE)
                                             ? 0.0
                                             : aframe->best_effort_timestamp * av_q2d(tb);
                        std::cout << "[A] frame " << decoded_audio
                                  << " pts=" << pts_sec
                                  << " nb_samples=" << aframe->nb_samples
                                  << " ch=" << aframe->channels
                                  << " rate=" << aframe->sample_rate << "\n";
                        decoded_audio++;
                        if (decoded_audio >= MAX_A_FRAMES) break;
                    }
                    if (err == AVERROR(EAGAIN) || err == AVERROR_EOF) {
                        // ok
                    } else if (err < 0) {
                        fail("avcodec_receive_frame(audio)", err);
                    }
                } else if (err != AVERROR(EAGAIN)) {
                    fail("avcodec_send_packet(audio)", err);
                }
            }
    
            av_packet_unref(pkt);
            if (decoded_video >= MAX_V_FRAMES && decoded_audio >= MAX_A_FRAMES) break;
        }
    
        // Flush decoders
        auto flush_decoder = [&](AVCodecContext* ctx, const char* tag) {
            if (!ctx) return;
            avcodec_send_packet(ctx, nullptr);
            AVFrame* f = av_frame_alloc();
            while ((err = avcodec_receive_frame(ctx, f)) == 0) {
                std::cout << "[" << tag << "] flushed frame\n";
            }
            av_frame_free(&f);
        };
        flush_decoder(vctx, "V");
        flush_decoder(actx, "A");
    
        // Cleanup
        av_frame_free(&vframe);
        av_frame_free(&aframe);
        av_packet_free(&pkt);
    
        if (vctx) avcodec_free_context(&vctx);
        if (actx) avcodec_free_context(&actx);
    
        avformat_close_input(&fmt);
        avformat_network_deinit();
    
        std::cout << "Done.\n";
        return 0;
    }