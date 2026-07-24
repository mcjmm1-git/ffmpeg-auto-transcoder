FROM ubuntu:24.04

LABEL org.opencontainers.image.title="FFmpeg Auto Transcoder"
LABEL org.opencontainers.image.description="Automatic FFmpeg transcoding service with NVENC support"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive
ENV MEDIA_DIR=/media

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ffmpeg \
        jq \
        curl \
        bc \
        ttyd \
        ca-certificates \
        tzdata && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /media

WORKDIR /opt/ffmpeg-auto-transcoder

COPY . .

RUN chmod +x \
    transcoder.sh \
    monitor.sh \
    monitor-web.sh \
    lib/config.sh \
    lib/tmdb.sh \
    lib/omdb.sh

ENTRYPOINT ["./transcoder.sh"]
