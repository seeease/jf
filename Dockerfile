FROM alpine:3.20
RUN apk add --no-cache libgcc
ARG TARGETARCH
COPY jfai-linux-${TARGETARCH} /usr/local/bin/jfai
RUN chmod +x /usr/local/bin/jfai
EXPOSE 8080
ENTRYPOINT ["jfai"]
