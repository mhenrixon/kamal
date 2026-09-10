# escape=\
FROM alpine:3.20 AS base

RUN <<-EOF
    apk add --no-cache curl
    echo done
EOF

COPY <<"CONF" /etc/app.conf
listen = 8080
CONF

RUN ["/bin/sh", "-c", "echo hello"]

# a comment inside a continuation follows
RUN echo one && \
    # this comment is not part of the command
    echo two
